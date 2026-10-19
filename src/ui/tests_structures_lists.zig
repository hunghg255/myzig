//! Trees, outlines, tables and grid views through `Tester`: opening and
//! closing, choosing with clicks and keys, sorting, and virtualization
//! keeping the boxes built to a screenful whatever the count.
const std = @import("std");
const ui = @import("ui.zig");
const tree = @import("tree.zig");
const outline = @import("outline.zig");
const table = @import("table.zig");
const gridview = @import("gridview.zig");
const testing = std.testing;

const Files = struct {
    chosen: []const u8 = "",
    src: bool = false,
    ui_dir: bool = false,
    submits: u32 = 0,
    fn view(s: *Files, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(10) });
        defer ui.end(c);
        var tr = tree.tree(c, &s.chosen, .{});
        if (tr.item("src", "src", &s.src)) {
            defer tr.endChildren();
            if (tr.item("src/ui", "ui", &s.ui_dir)) {
                defer tr.endChildren();
                _ = tr.item("src/ui/list.zig", "list.zig", null);
            }
            _ = tr.item("src/main.zig", "main.zig", null);
        }
        _ = tr.item("build.zig", "build.zig", null);
        if (tr.end().submitted) s.submits += 1;
    }
};

test "tree: the arrow opens and closes, a click elsewhere chooses" {
    var s: Files = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Files.view), .{});
    defer t.deinit();
    try testing.expect(!t.hasText("main.zig"));
    try t.clickText("src");
    try testing.expectEqualStrings("src", s.chosen);
    try testing.expect(!s.src);
    // The arrow is just before the label.
    const label = t.findText("src").?;
    t.click(label.x - 10, label.y + label.h / 2);
    try testing.expect(s.src);
    try testing.expect(t.hasText("main.zig") and t.hasText("ui"));
    // Children are indented.
    try testing.expect(t.findText("main.zig").?.x > label.x + 10);
    try t.clickText("main.zig");
    try testing.expectEqualStrings("src/main.zig", s.chosen);
    const r = t.findText("build.zig").?;
    t.doubleClick(r.x + 2, r.y + 2);
    try testing.expectEqualStrings("build.zig", s.chosen);
    try testing.expectEqual(@as(u32, 1), s.submits);
}

test "tree: Up, Down, Right and Left move through the items, open and close them" {
    var s: Files = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Files.view), .{});
    defer t.deinit();
    try t.clickText("src");
    t.key(.down);
    try testing.expectEqualStrings("build.zig", s.chosen);
    t.key(.up);
    t.key(.right);
    try testing.expect(s.src);
    try testing.expectEqualStrings("src", s.chosen);
    t.key(.right);
    try testing.expectEqualStrings("src/ui", s.chosen);
    t.key(.right);
    t.key(.down);
    try testing.expectEqualStrings("src/ui/list.zig", s.chosen);
    t.key(.down);
    try testing.expectEqualStrings("src/main.zig", s.chosen);
    t.key(.left);
    try testing.expectEqualStrings("src", s.chosen);
    t.key(.left);
    try testing.expect(!s.src);
    try testing.expect(!t.hasText("main.zig"));
    t.key(.end);
    try testing.expectEqualStrings("build.zig", s.chosen);
    t.key(.enter);
    try testing.expectEqual(@as(u32, 1), s.submits);
}

/// A tree of 1000 directories of 1000 files each, numbered: directory d is
/// d, its file f is 1_000_000 + d * 1000 + f.
const Big = struct {
    state: outline.OutlineState(u32) = .{},
    roots: [1000]u32 = blk: {
        var r: [1000]u32 = undefined;
        for (&r, 0..) |*v, i| v.* = @intCast(i);
        break :blk r;
    },
    files: [1000]u32 = undefined,
    submits: u32 = 0,

    pub fn children(s: *Big, item: u32) []const u32 {
        if (item >= 1_000_000) return &.{};
        for (&s.files, 0..) |*v, f| v.* = 1_000_000 + item * 1000 + @as(u32, @intCast(f));
        return &s.files;
    }

    fn view(s: *Big, c: *ui.Context) void {
        var rows = outline.outline(u32, c, &s.state, &s.roots, s, .{ .row_height = 24 });
        while (rows.next()) |r| {
            if (r.item >= 1_000_000) {
                const d = (r.item - 1_000_000) / 1000;
                ui.text(c, c.print("file {d}.{d}", .{ d, r.item % 1000 }), .{});
            } else ui.text(c, c.print("dir {d}", .{r.item}), .{});
        }
        if (rows.end().submitted) s.submits += 1;
    }
};

test "outline: builds only the rows in view, opens and closes, and the keys move" {
    var s: Big = .{};
    defer s.state.deinit(testing.allocator);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Big.view), .{ .height = 300 });
    defer t.deinit();
    const few = t.ctx.nodes.items.len;
    try testing.expect(few < 150);
    try testing.expect(t.hasText("dir 0") and !t.hasText("dir 100"));
    // Open the first directory: a thousand more rows, as few boxes.
    const d0 = t.findText("dir 0").?;
    t.click(d0.x - 10, d0.y + d0.h / 2);
    try testing.expect(s.state.isOpen(0));
    try testing.expect(t.hasText("file 0.0"));
    try testing.expect(t.ctx.nodes.items.len < 150);
    try testing.expect(t.findText("file 0.0").?.x > d0.x + 10);

    // Choose a file, and go down a page and back by keys.
    try t.clickText("file 0.2");
    try testing.expectEqual(@as(?u32, 1_000_002), s.state.selected);
    t.key(.down);
    try testing.expectEqual(@as(?u32, 1_000_003), s.state.selected);
    // Far down: the choice stays in view.
    for (0..30) |_| t.key(.page_down);
    const sel = s.state.selected.?;
    try testing.expect(sel > 1_000_200);
    const label = t.findText(t.ctx.print("file 0.{d}", .{sel % 1000})) orelse return error.ChoiceOutOfView;
    try testing.expect(label.y >= 0 and label.y + label.h <= 300);
    try testing.expect(t.ctx.nodes.items.len < 150);
    // Left goes to the parent, then closes it.
    t.key(.left);
    try testing.expectEqual(@as(?u32, 0), s.state.selected);
    t.key(.left);
    try testing.expect(!s.state.isOpen(0));
    try testing.expect(t.hasText("dir 0") and t.hasText("dir 1"));
    // Right opens, Right again goes to its first child; Enter submits.
    t.key(.right);
    t.key(.right);
    try testing.expectEqual(@as(?u32, 1_000_000), s.state.selected);
    t.key(.enter);
    try testing.expectEqual(@as(u32, 1), s.submits);
    // Closing with the arrow, while a child is chosen, chooses the item.
    const d = t.findText("dir 0").?;
    t.click(d.x - 10, d.y + d.h / 2);
    try testing.expect(!s.state.isOpen(0));
    try testing.expectEqual(@as(?u32, 0), s.state.selected);
    // The end of all the roots.
    t.key(.end);
    try testing.expectEqual(@as(?u32, 999), s.state.selected);
    try testing.expect(t.hasText("dir 999"));
}

test "outline: string items" {
    const Tree = struct {
        state: outline.OutlineState([]const u8) = .{},
        pub fn children(_: *@This(), item: []const u8) []const []const u8 {
            if (std.mem.eql(u8, item, "/")) return &.{ "/a", "/b" };
            return &.{};
        }
        fn view(s: *@This(), c: *ui.Context) void {
            var rows = outline.outline([]const u8, c, &s.state, &.{"/"}, s, .{});
            while (rows.next()) |r| ui.text(c, r.item, .{});
            _ = rows.end();
        }
    };
    var s: Tree = .{};
    defer s.state.deinit(testing.allocator);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Tree.view), .{});
    defer t.deinit();
    try t.clickText("/");
    t.key(.right);
    try testing.expect(s.state.isOpen("/"));
    try testing.expect(t.hasText("/b"));
    t.key(.down);
    t.key(.down);
    try testing.expectEqualStrings("/b", s.state.selected.?);
}

const People = struct {
    state: table.TableState = .{},
    order: [100_000]u32 = undefined,
    submits: u32 = 0,
    sorts: u32 = 0,
    const cols: []const table.Column = &.{
        .{ .title = "Name", .sortable = true },
        .{ .title = "Age", .width = 80, .alignment = .end, .sortable = true },
        .{ .title = "Notes", .width = 100 },
    };
    fn init(s: *People) void {
        for (&s.order, 0..) |*v, i| v.* = @intCast(i);
    }
    fn view(s: *People, c: *ui.Context) void {
        var tb = table.table(c, &s.state, cols, s.order.len, .{});
        while (tb.next()) |row| {
            const p = s.order[row];
            while (tb.cell()) |col| switch (col) {
                0 => ui.text(c, c.print("Person {d}", .{p}), .{ .color = tb.textColor() }),
                1 => ui.text(c, c.print("{d}", .{p % 90}), .{}),
                else => ui.text(c, "-", .{}),
            };
        }
        const r = tb.end();
        if (r.sorted) {
            s.sorts += 1;
            const desc = s.state.sort.?.descending;
            std.mem.reverse(u32, &s.order);
            if (!desc and s.order[0] != 0) std.mem.reverse(u32, &s.order);
        }
        if (r.submitted) s.submits += 1;
    }
};

test "table: a header over columns, rows chosen by clicks and keys, a screenful built" {
    var s: People = .{};
    s.init();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, People.view), .{ .width = 480, .height = 300 });
    defer t.deinit();
    try testing.expect(t.ctx.nodes.items.len < 200);
    // Columns line up under their headers: the fixed ones at the end.
    const age = t.findText("Age").?;
    const notes = t.findText("Notes").?;
    try testing.expectApproxEqAbs(@as(f32, 480 - 100 - 8), age.x + age.w, 1);
    try testing.expectApproxEqAbs(@as(f32, 480 - 100 + 8), notes.x, 1);
    try testing.expectApproxEqAbs(t.findText("Person 0").?.x, t.findText("Name").?.x, 0.5);
    try t.clickText("Person 3");
    try testing.expectEqual(@as(?usize, 3), s.state.selected);
    t.key(.down);
    try testing.expectEqual(@as(?usize, 4), s.state.selected);
    t.key(.end);
    try testing.expectEqual(@as(?usize, 99_999), s.state.selected);
    try testing.expect(t.hasText("Person 99999"));
    try testing.expect(t.ctx.nodes.items.len < 200);
    t.key(.home);
    try testing.expect(t.hasText("Person 0"));
    t.key(.enter);
    try testing.expectEqual(@as(u32, 1), s.submits);
    const r = t.findText("Person 1").?;
    t.doubleClick(r.x + 2, r.y + 2);
    try testing.expectEqual(@as(?usize, 1), s.state.selected);
    try testing.expectEqual(@as(u32, 2), s.submits);
}

test "table: a click on a sortable header sorts by it, a second reverses" {
    var s: People = .{};
    s.init();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, People.view), .{ .width = 480, .height = 300 });
    defer t.deinit();
    try testing.expect(s.state.sort == null);
    try t.clickText("Name");
    try testing.expectEqual(@as(usize, 0), s.state.sort.?.column);
    try testing.expect(!s.state.sort.?.descending);
    try testing.expect(t.hasText("Person 0"));
    try t.clickText("Name");
    try testing.expect(s.state.sort.?.descending);
    try testing.expect(t.hasText("Person 99999"));
    try testing.expect(!t.hasText("Person 0"));
    try t.clickText("Age");
    try testing.expectEqual(@as(usize, 1), s.state.sort.?.column);
    try testing.expect(!s.state.sort.?.descending);
    // A column that does not sort takes no click.
    try t.clickText("Notes");
    try testing.expectEqual(@as(usize, 1), s.state.sort.?.column);
    try testing.expectEqual(@as(u32, 3), s.sorts);
}

const Photos = struct {
    state: gridview.GridState = .{},
    count: usize = 1_000_000,
    submits: u32 = 0,
    fn view(s: *Photos, c: *ui.Context) void {
        var g = gridview.gridView(c, &s.state, .{ .count = s.count, .min_item_width = 100, .row_height = 80, .gap = 10, .padding = .all(10) });
        while (g.next()) |i| ui.text(c, c.print("Photo {d}", .{i}), .{});
        if (g.end().submitted) s.submits += 1;
    }
};

test "grid view: as many columns as fit, a screenful built, the arrows move both ways" {
    var s: Photos = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Photos.view), .{ .width = 480, .height = 300 });
    defer t.deinit();
    t.frame();
    // 460 points inside: four columns of at least 100, 10 apart.
    try testing.expectEqual(@as(usize, 4), gridview.columnsFor(460, 100, 10));
    const p0 = t.findText("Photo 0").?;
    const p1 = t.findText("Photo 1").?;
    const p4 = t.findText("Photo 4").?;
    try testing.expectApproxEqAbs(p0.y, p1.y, 0.5);
    try testing.expectApproxEqAbs(p0.x, p4.x, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 90), p4.y - p0.y, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 117.5), p1.x - p0.x, 0.5);
    try testing.expect(t.ctx.nodes.items.len < 200);

    try t.clickText("Photo 5");
    try testing.expectEqual(@as(?usize, 5), s.state.selected);
    t.key(.down);
    try testing.expectEqual(@as(?usize, 9), s.state.selected);
    t.key(.right);
    try testing.expectEqual(@as(?usize, 10), s.state.selected);
    t.key(.up);
    t.key(.left);
    try testing.expectEqual(@as(?usize, 5), s.state.selected);
    t.key(.end);
    try testing.expectEqual(@as(?usize, 999_999), s.state.selected);
    try testing.expect(t.hasText("Photo 999999"));
    try testing.expect(t.ctx.nodes.items.len < 200);
    t.key(.enter);
    try testing.expectEqual(@as(u32, 1), s.submits);

    // Wider: more columns.
    t.resize(700, 300);
    t.frame();
    t.key(.home);
    const q0 = t.findText("Photo 0").?;
    // 680 points inside: six columns.
    const q5 = t.findText("Photo 5") orelse return error.NotBuilt;
    try testing.expectApproxEqAbs(q0.y, q5.y, 0.5);
    try testing.expect(t.findText("Photo 6").?.y > q0.y);
}

test "grid view: a last row short of items keeps its columns' widths" {
    var s: Photos = .{ .count = 6 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Photos.view), .{ .width = 480, .height = 300 });
    defer t.deinit();
    t.frame();
    try testing.expectApproxEqAbs(t.findText("Photo 0").?.x, t.findText("Photo 4").?.x, 0.5);
    try testing.expectApproxEqAbs(t.findText("Photo 1").?.x, t.findText("Photo 5").?.x, 0.5);
}
