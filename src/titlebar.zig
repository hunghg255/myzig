//! Where native UI moves its window, the same on every platform: in a
//! window with a hidden title bar, or a frameless one given a title bar
//! height, the top strip moves the window as a title bar does, but where
//! an interactive box (a button, a tab, a field) is: those take the press.
const std = @import("std");
const ui_types = @import("ui/types.zig");

/// Whether a press at `x`, `y` (points in the content) moves the window:
/// it is in the top `height` and over no interactive box of the frame
/// last painted (`ctx` is a `ui.Context`); `height` is `strip`'s.
pub fn draggable(ctx: anytype, x: f32, y: f32, height: f32) bool {
    if (y < 0 or y >= height or x < 0) return false;
    const p: ui_types.Point = .{ .x = x, .y = y };
    var i = ctx.hits.items.len;
    while (i > 0) {
        i -= 1;
        const h = ctx.hits.items[i];
        if (!h.scroll and h.contains(p)) return false;
    }
    return true;
}

/// The height of the strip that moves a window: the title bar's under a
/// hidden one (or the view's, `Context.title_bar_height`, if taller), the
/// one asked for in a frameless window, none in a framed one.
pub fn strip(kind: anytype, asked: f64, view: f32, system: f64) f32 {
    return switch (kind) {
        .default => 0,
        .hidden => @max(view, @as(f32, @floatCast(if (asked > 0) asked else system))),
        .frameless => @floatCast(asked),
    };
}

test "the empty top of a hidden title bar moves the window, not its buttons" {
    const Hit = @import("ui/hit.zig").Hit;
    const Ctx = struct { hits: std.ArrayList(Hit) };
    var ctx: Ctx = .{ .hits = .empty };
    defer ctx.hits.deinit(std.testing.allocator);
    try ctx.hits.append(std.testing.allocator, .{ .id = 1, .index = 0, .rect = .{ .x = 10, .y = 4, .w = 60, .h = 24 }, .scroll = false });
    // A scrolling box takes no press of its own.
    try ctx.hits.append(std.testing.allocator, .{ .id = 2, .index = 1, .rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 }, .scroll = true });
    try std.testing.expect(draggable(&ctx, 200, 10, 32));
    try std.testing.expect(!draggable(&ctx, 20, 10, 32));
    try std.testing.expect(!draggable(&ctx, 200, 40, 32));
    const TB = enum { default, hidden, frameless };
    try std.testing.expectEqual(@as(f32, 32), strip(TB.hidden, 0, 28, 32));
    try std.testing.expectEqual(@as(f32, 48), strip(TB.hidden, 0, 48, 32));
    try std.testing.expectEqual(@as(f32, 0), strip(TB.frameless, 0, 28, 32));
    try std.testing.expectEqual(@as(f32, 0), strip(TB.default, 40, 28, 32));
}
