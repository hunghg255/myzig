//! Search fields, token fields and avatars through `Tester`.
const std = @import("std");
const ui = @import("ui.zig");
const fields = @import("controls_fields.zig");
const testing = std.testing;

const Search = struct {
    query: ui.TextBuffer = .{},
    changes: u32 = 0,
    submits: u32 = 0,
    clears: u32 = 0,
    fn view(s: *Search, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        const r = fields.searchField(c, &s.query, .{});
        if (r.changed) s.changes += 1;
        if (r.submitted) s.submits += 1;
        if (r.cleared) s.clears += 1;
        ui.text(c, "Elsewhere", .{});
    }
};

fn clearButton(t: *ui.Tester) ?ui.Rect {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .icon => |ic| if (std.mem.eql(u8, ic.name, "xmark")) return t.ctx.nodes.items[n.parent].rect,
        else => {},
    };
    return null;
}

test "a search field types, submits, and clears with its button or Escape" {
    var s: Search = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Search.view), .{});
    defer t.deinit();
    try testing.expect(t.hasText("Search"));
    try testing.expect(clearButton(&t) == null);
    try t.clickText("Search");
    t.typeText("mail");
    try testing.expectEqualStrings("mail", s.query.text());
    try testing.expect(s.changes >= 1);
    t.key(.enter);
    try testing.expectEqual(@as(u32, 1), s.submits);
    // The button clears it and keeps the focus: typing goes on.
    const b = clearButton(&t).?;
    t.click(b.x + b.w / 2, b.y + b.h / 2);
    try testing.expectEqualStrings("", s.query.text());
    try testing.expectEqual(@as(u32, 1), s.clears);
    try testing.expect(clearButton(&t) == null);
    t.typeText("abc");
    try testing.expectEqualStrings("abc", s.query.text());
    // Escape clears a field holding text, then gives up the focus.
    t.key(.escape);
    try testing.expectEqualStrings("", s.query.text());
    try testing.expectEqual(@as(u32, 2), s.clears);
    t.typeText("x");
    try testing.expectEqualStrings("x", s.query.text());
    t.key(.backspace);
    t.key(.escape);
    t.typeText("y");
    try testing.expectEqualStrings("", s.query.text());
}

test "a click on the search field's frame focuses its text" {
    var s: Search = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Search.view), .{});
    defer t.deinit();
    // On the magnifying glass, left of the text.
    const r = t.findText("Search").?;
    t.click(r.x - 12, r.y + r.h / 2);
    t.typeText("q");
    try testing.expectEqualStrings("q", s.query.text());
}

const Tags = struct {
    tags: fields.Tokens = .{},
    changes: u32 = 0,
    fn view(s: *Tags, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        if (fields.tokenField(c, &s.tags, &.{ "design", "development", "docs", "devops", "marketing" }, .{ .placeholder = "Add tags", .width = 260 })) s.changes += 1;
        ui.text(c, "Elsewhere", .{});
    }
};

fn tokenList(t: *const fields.Tokens, buf: []u8) []const u8 {
    var n: usize = 0;
    for (0..t.count) |i| {
        if (i > 0) {
            buf[n] = '|';
            n += 1;
        }
        @memcpy(buf[n .. n + t.get(i).len], t.get(i));
        n += t.get(i).len;
    }
    return buf[0..n];
}

test "tokens keep their text, refuse duplicates, and are taken out" {
    var t: fields.Tokens = .{};
    var buf: [256]u8 = undefined;
    try testing.expect(t.append(" a "));
    try testing.expect(t.append("bb"));
    try testing.expect(!t.append("a"));
    try testing.expect(!t.append("  "));
    try testing.expect(t.append("ccc"));
    try testing.expectEqualStrings("a|bb|ccc", tokenList(&t, &buf));
    t.remove(1);
    try testing.expectEqualStrings("a|ccc", tokenList(&t, &buf));
    t.remove(0);
    try testing.expectEqualStrings("ccc", tokenList(&t, &buf));
    t.remove(5);
    try testing.expectEqual(@as(usize, 1), t.count);
}

test "Enter and commas add tokens, Backspace while empty takes out the last" {
    var s: Tags = .{};
    var t: ui.Tester = undefined;
    var buf: [256]u8 = undefined;
    try t.init(testing.allocator, .init(&s, Tags.view), .{});
    defer t.deinit();
    try t.clickText("Add tags");
    t.typeText("zig");
    t.key(.enter);
    try testing.expectEqualStrings("zig", tokenList(&s.tags, &buf));
    try testing.expectEqualStrings("", s.tags.query.text());
    try testing.expect(t.hasText("zig"));
    t.typeText("ui, gpu,");
    try testing.expectEqualStrings("zig|ui|gpu", tokenList(&s.tags, &buf));
    t.typeText("zig");
    t.key(.enter);
    try testing.expectEqualStrings("zig|ui|gpu", tokenList(&s.tags, &buf));
    t.typeText("ab");
    // Backspace edits the text first, then takes out tokens.
    t.key(.backspace);
    t.key(.backspace);
    try testing.expectEqual(@as(usize, 3), s.tags.count);
    t.key(.backspace);
    try testing.expectEqualStrings("zig|ui", tokenList(&s.tags, &buf));
    try testing.expect(!t.hasText("gpu"));
    try testing.expectEqual(@as(u32, 3), s.changes);
}

test "a chip's button takes its token out" {
    var s: Tags = .{};
    _ = s.tags.append("alpha");
    _ = s.tags.append("beta");
    var t: ui.Tester = undefined;
    var buf: [256]u8 = undefined;
    try t.init(testing.allocator, .init(&s, Tags.view), .{});
    defer t.deinit();
    const r = t.findText("alpha").?;
    // Its button follows the text: 4 of gap, 16 wide.
    t.click(r.x + r.w + 4 + 8, r.y + r.h / 2);
    try testing.expectEqualStrings("beta", tokenList(&s.tags, &buf));
}

test "suggestions show what matches, Up and Down move, Enter or a click adds" {
    var s: Tags = .{};
    var t: ui.Tester = undefined;
    var buf: [256]u8 = undefined;
    try t.init(testing.allocator, .init(&s, Tags.view), .{});
    defer t.deinit();
    try t.clickText("Add tags");
    t.typeText("De");
    // Ignoring case: design, development, devops; not docs or marketing.
    try testing.expect(t.hasText("design") and t.hasText("development") and t.hasText("devops"));
    try testing.expect(!t.hasText("docs") and !t.hasText("marketing"));
    t.key(.down);
    t.key(.enter);
    try testing.expectEqualStrings("development", tokenList(&s.tags, &buf));
    // A suggestion already a token is not shown again.
    t.typeText("dev");
    try testing.expect(t.hasText("devops"));
    var n: usize = 0;
    for (t.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, "development")) {
            n += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), n); // the chip only
    try t.clickText("devops");
    try testing.expectEqualStrings("development|devops", tokenList(&s.tags, &buf));
    try testing.expectEqualStrings("", s.tags.query.text());
    // The field kept the focus.
    t.typeText("x");
    try testing.expectEqualStrings("x", s.tags.query.text());
    // Up wraps round to the last.
    t.key(.backspace);
    t.typeText("d");
    t.key(.up);
    t.key(.enter);
    try testing.expectEqualStrings("development|devops|docs", tokenList(&s.tags, &buf));
}

test "chips wrap onto more lines as they fill the field" {
    var s: Tags = .{};
    for ([_][]const u8{ "one", "two", "three", "four", "five", "six", "seven", "eight" }) |w| _ = s.tags.append(w);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Tags.view), .{});
    defer t.deinit();
    const first = t.findText("one").?;
    const last = t.findText("eight").?;
    try testing.expect(last.y > first.y + 10);
    // Every chip fits in the field.
    for ([_][]const u8{ "one", "two", "three", "four", "five", "six", "seven", "eight" }) |w| {
        const r = t.findText(w).?;
        try testing.expect(r.x + r.w <= 20 + 260);
    }
    // A click on the field focuses its input, which still adds.
    t.click(270, last.y + last.h / 2);
    t.typeText("nine");
    t.key(.enter);
    try testing.expectEqual(@as(usize, 9), s.tags.count);
    try testing.expectEqualStrings("nine", s.tags.get(8));
}

test "initials and colors of avatars" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("AL", fields.initials("Ada Lovelace", &buf));
    try testing.expectEqualStrings("GH", fields.initials("  grace  brewster  hopper ", &buf));
    try testing.expectEqualStrings("Z", fields.initials("zig", &buf));
    try testing.expectEqualStrings("", fields.initials(" -- ", &buf));
    try testing.expectEqualStrings("ÉZ", fields.initials("Émile Zola", &buf));
    // A name keeps its color; names differ.
    try testing.expectEqual(fields.avatarColor("Ada"), fields.avatarColor("Ada"));
    try testing.expect(!std.meta.eql(fields.avatarColor("Ada"), fields.avatarColor("Alan")));
}

const People = struct {
    fn view(_: *People, c: *ui.Context) void {
        ui.row(c, .{ .padding = .all(20), .gap = 8 });
        defer ui.end(c);
        fields.avatar(c, "Ada Lovelace", .{ .size = 40 });
        fields.avatar(c, "Alan", .{ .image = .{ .key = "none", .bytes = "not a picture" } });
    }
};

test "an avatar is a circle of initials, and falls back to them without a picture" {
    var s: People = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, People.view), .{});
    defer t.deinit();
    const r = t.findText("AL").?;
    try testing.expect(t.hasText("A"));
    // Centered in its circle of 40.
    var circle: ?ui.Rect = null;
    for (t.ctx.nodes.items) |n| if (n.style.radius == 20) {
        circle = n.rect;
    };
    try testing.expectEqual(@as(f32, 40), circle.?.w);
    try testing.expectApproxEqAbs(circle.?.x + 20, r.x + r.w / 2, 0.6);
    try testing.expectApproxEqAbs(circle.?.y + 20, r.y + r.h / 2, 0.6);
}
