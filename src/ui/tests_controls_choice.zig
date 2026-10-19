//! Radio buttons, ratings, links and history buttons through `Tester`.
const std = @import("std");
const ui = @import("ui.zig");
const choice = @import("controls_choice.zig");
const testing = std.testing;

const Size = enum { small, medium, large };

const Radios = struct {
    size: Size = .medium,
    align_: u8 = 0,
    changes: u32 = 0,
    fn view(s: *Radios, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        if (choice.radioGroup(c, &s.size, &.{
            .{ .label = "Small", .value = .small },
            .{ .label = "Medium", .value = .medium },
            .{ .label = "Large", .value = .large },
        }, .{})) s.changes += 1;
        ui.row(c, .{ .gap = 12 });
        _ = choice.radio(c, &s.align_, 0, "Left");
        _ = choice.radio(c, &s.align_, 1, "Center");
        _ = choice.radio(c, &s.align_, 2, "Right");
        ui.end(c);
        ui.text(c, "Elsewhere", .{});
    }
};

test "a click selects a radio button, and selecting it again changes nothing" {
    var s: Radios = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Radios.view), .{});
    defer t.deinit();
    try t.clickText("Large");
    try testing.expectEqual(Size.large, s.size);
    try testing.expectEqual(@as(u32, 1), s.changes);
    try t.clickText("Large");
    try testing.expectEqual(@as(u32, 1), s.changes);
    try t.clickText("Center");
    try testing.expectEqual(@as(u8, 1), s.align_);
    try t.clickText("Right");
    try testing.expectEqual(@as(u8, 2), s.align_);
    // The group's choice is untouched by the other radios.
    try testing.expectEqual(Size.large, s.size);
}

test "the arrows, Home and End choose within a focused radio group" {
    var s: Radios = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Radios.view), .{});
    defer t.deinit();
    try t.clickText("Small");
    try testing.expectEqual(Size.small, s.size);
    t.key(.down);
    try testing.expectEqual(Size.medium, s.size);
    t.key(.right);
    try testing.expectEqual(Size.large, s.size);
    // At the end it stays.
    t.key(.down);
    try testing.expectEqual(Size.large, s.size);
    t.key(.home);
    try testing.expectEqual(Size.small, s.size);
    t.key(.up);
    try testing.expectEqual(Size.small, s.size);
    t.key(.end);
    try testing.expectEqual(Size.large, s.size);
    try testing.expectEqual(@as(u32, 5), s.changes);
    // Without the focus the keys do nothing.
    try t.clickText("Elsewhere");
    t.key(.home);
    try testing.expectEqual(Size.large, s.size);
}

const Stars = struct {
    value: u8 = 0,
    changes: u32 = 0,
    fn view(s: *Stars, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        if (choice.rating(c, &s.value, .{ .size = 20 })) s.changes += 1;
        ui.text(c, "Below", .{});
    }
};

/// The middle of star `k` (0-based): the row starts at 20 + 2 of padding,
/// stars 20 wide with gaps of 2.
fn starX(k: f32) f32 {
    return 22 + k * 22 + 10;
}

test "a click on a star rates, a click on the star set clears" {
    var s: Stars = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Stars.view), .{});
    defer t.deinit();
    t.click(starX(2), 32);
    try testing.expectEqual(@as(u8, 3), s.value);
    t.click(starX(4), 32);
    try testing.expectEqual(@as(u8, 5), s.value);
    t.click(starX(4), 32);
    try testing.expectEqual(@as(u8, 0), s.value);
    try testing.expectEqual(@as(u32, 3), s.changes);
}

test "the keys change a focused rating within its bounds" {
    var s: Stars = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Stars.view), .{});
    defer t.deinit();
    t.click(starX(0), 32);
    try testing.expectEqual(@as(u8, 1), s.value);
    t.key(.right);
    t.key(.up);
    try testing.expectEqual(@as(u8, 3), s.value);
    t.key(.end);
    try testing.expectEqual(@as(u8, 5), s.value);
    t.key(.right);
    try testing.expectEqual(@as(u8, 5), s.value);
    t.key(.left);
    try testing.expectEqual(@as(u8, 4), s.value);
    t.key(.home);
    try testing.expectEqual(@as(u8, 0), s.value);
    t.key(.down);
    try testing.expectEqual(@as(u8, 0), s.value);
}

test "the stars under the pointer show what a click would set" {
    var s: Stars = .{ .value = 1 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Stars.view), .{});
    defer t.deinit();
    const filled = struct {
        fn count(tt: *ui.Tester) usize {
            var n: usize = 0;
            for (tt.ctx.nodes.items) |node| switch (node.content) {
                .icon => |ic| if (!std.meta.eql(ic.color, tt.theme.track)) {
                    n += 1;
                },
                else => {},
            };
            return n;
        }
    }.count;
    try testing.expectEqual(@as(usize, 1), filled(&t));
    t.moveTo(starX(3), 32);
    try testing.expectEqual(@as(usize, 4), filled(&t));
    t.moveTo(300, 300);
    try testing.expectEqual(@as(usize, 1), filled(&t));
}

const Links = struct {
    clicks: u32 = 0,
    fn view(s: *Links, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        if (choice.link(c, "Privacy policy", .{})) s.clicks += 1;
        ui.text(c, "Plain", .{});
    }
};

test "a link is clicked, underlined under the pointer, and follows Enter" {
    var s: Links = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Links.view), .{});
    defer t.deinit();
    const underlined = struct {
        fn f(tt: *ui.Tester) bool {
            for (tt.ctx.nodes.items) |n| switch (n.content) {
                .text => |tx| if (std.mem.eql(u8, tx.str, "Privacy policy")) return tx.spans.len == 1 and tx.spans[0].underline,
                else => {},
            };
            return false;
        }
    }.f;
    try testing.expect(!underlined(&t));
    const r = t.findText("Privacy policy").?;
    t.moveTo(r.x + 5, r.y + r.h / 2);
    try testing.expect(underlined(&t));
    try t.clickText("Privacy policy");
    try testing.expectEqual(@as(u32, 1), s.clicks);
    t.key(.enter);
    try testing.expectEqual(@as(u32, 2), s.clicks);
    try t.clickText("Plain");
    t.key(.enter);
    try testing.expectEqual(@as(u32, 2), s.clicks);
}

const Pages = struct {
    at: usize = 0,
    count: usize = 3,
    fn view(s: *Pages, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        switch (choice.historyButtons(c, .{ .can_back = s.at > 0, .can_forward = s.at + 1 < s.count })) {
            .back => s.at -= 1,
            .forward => s.at += 1,
            .none => {},
        }
        ui.textf(c, .{}, "Page {d}", .{s.at});
    }
};

test "history buttons go back and forward, disabled at the ends" {
    var s: Pages = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Pages.view), .{});
    defer t.deinit();
    // Back at the start does nothing; the buttons are 28 wide from x 20.
    t.click(34, 33);
    try testing.expectEqual(@as(usize, 0), s.at);
    t.click(64, 33);
    t.click(64, 33);
    try testing.expectEqual(@as(usize, 2), s.at);
    t.click(64, 33);
    try testing.expectEqual(@as(usize, 2), s.at);
    t.click(34, 33);
    try testing.expectEqual(@as(usize, 1), s.at);
    try testing.expect(t.hasText("Page 1"));
    // And the keys of the platform.
    const mac = @import("builtin").os.tag == .macos;
    try testing.expect(t.shortcut(if (mac) .{ .key = '[', .cmd = true } else .{ .key = ui.Shortcut.left, .alt = true }));
    try testing.expectEqual(@as(usize, 0), s.at);
    try testing.expect(!t.shortcut(if (mac) .{ .key = '[', .cmd = true } else .{ .key = ui.Shortcut.left, .alt = true }));
    try testing.expect(t.shortcut(if (mac) .{ .key = ']', .cmd = true } else .{ .key = ui.Shortcut.right, .alt = true }));
    try testing.expectEqual(@as(usize, 1), s.at);
}
