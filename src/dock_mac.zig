//! A task's progress on the app's Dock icon (macOS): the Dock tile's
//! content view draws the app's icon and a bar across its bottom, as
//! Finder's copies and Safari's downloads show. The Dock has one icon for
//! the app, so the last window's progress is the one it shows; `.none`
//! gives the tile back its plain icon.
const std = @import("std");
const objc = @import("objc.zig");
const Progress = @import("window_types.zig").Progress;

/// What the tile's view draws.
var shown: Progress = .{ .state = .none };
var view: ?objc.Object = null;

/// The bar's frame in a tile of `size` (points): along its bottom.
pub fn barRect(size: objc.CGSize) objc.CGRect {
    const inset = size.width * 0.12;
    const h = @max(6, size.height * 0.1);
    return .{ .origin = .{ .x = inset, .y = size.height * 0.08 }, .size = .{ .width = size.width - 2 * inset, .height = h } };
}

/// The filled part of the bar of `p` in `bar`; an indeterminate one is full.
pub fn fillRect(bar: objc.CGRect, p: Progress) objc.CGRect {
    var r = bar;
    const v: f64 = if (p.state == .indeterminate) 1 else std.math.clamp(p.value, 0, 1);
    r.size.width = bar.size.width * v;
    return r;
}

/// The fill's color: red when it failed, yellow while paused, else the
/// accent's blue (calibrated RGBA).
pub fn fillColor(state: Progress.State) [4]f64 {
    return switch (state) {
        .failed => .{ 0.92, 0.26, 0.21, 1 },
        .paused => .{ 0.98, 0.75, 0.18, 1 },
        else => .{ 0.04, 0.52, 1, 1 },
    };
}

fn color(rgba: [4]f64) objc.Object {
    return objc.msg(objc.Object, objc.class("NSColor"), "colorWithCalibratedRed:green:blue:alpha:", .{ rgba[0], rgba[1], rgba[2], rgba[3] });
}

fn roundedRect(r: objc.CGRect) objc.Object {
    const radius = r.size.height / 2;
    return objc.msg(objc.Object, objc.class("NSBezierPath"), "bezierPathWithRoundedRect:xRadius:yRadius:", .{ r, radius, radius });
}

fn drawRect(self: objc.Object, _: objc.SEL, _: objc.CGRect) callconv(.c) void {
    const bounds = objc.msg(objc.CGRect, self, "bounds", .{});
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    if (objc.msg(?objc.Object, nsapp, "applicationIconImage", .{})) |icon| {
        // NSCompositingOperationSourceOver.
        objc.msg(void, icon, "drawInRect:fromRect:operation:fraction:", .{ bounds, objc.CGRect{}, @as(objc.NSUInteger, 2), @as(objc.CGFloat, 1) });
    }
    if (shown.state == .none) return;
    const bar = barRect(bounds.size);
    objc.msg(void, color(.{ 0, 0, 0, 0.55 }), "setFill", .{});
    objc.msg(void, roundedRect(bar), "fill", .{});
    const inner: objc.CGRect = .{ .origin = .{ .x = bar.origin.x + 1, .y = bar.origin.y + 1 }, .size = .{ .width = bar.size.width - 2, .height = bar.size.height - 2 } };
    const fill = fillRect(inner, shown);
    if (fill.size.width <= 0) return;
    objc.msg(void, color(fillColor(shown.state)), "setFill", .{});
    objc.msg(void, roundedRect(fill), "fill", .{});
}

fn tileView(tile: objc.Object) objc.Object {
    if (view) |v| return v;
    const cls = objc.defineClass(.{
        .name = "MyZigDockProgressView",
        .superclass = "NSView",
        .methods = &.{.{ .name = "drawRect:", .imp = &drawRect, .types = "v@:{CGRect={CGPoint=dd}{CGSize=dd}}" }},
    });
    const size = objc.msg(objc.CGSize, tile, "size", .{});
    const v = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "initWithFrame:", .{objc.CGRect{ .size = size }});
    view = v;
    return v;
}

/// Shows `p` on the Dock icon; always true (the Dock always has a tile).
pub fn setProgress(nsapp: objc.Object, p: Progress) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const tile = objc.msg(objc.Object, nsapp, "dockTile", .{});
    shown = p;
    if (p.state == .none) {
        objc.msg(void, tile, "setContentView:", .{@as(?objc.Object, null)});
    } else {
        objc.msg(void, tile, "setContentView:", .{tileView(tile)});
    }
    objc.msg(void, tile, "display", .{});
    return true;
}

test "the Dock's bar: along the bottom, filled by the value, colored by the state" {
    const bar = barRect(.{ .width = 128, .height = 128 });
    try std.testing.expect(bar.origin.y < 20 and bar.size.width > 90);
    try std.testing.expectEqual(bar.size.width / 2, fillRect(bar, .{ .state = .normal, .value = 0.5 }).size.width);
    try std.testing.expectEqual(bar.size.width, fillRect(bar, .{ .state = .indeterminate }).size.width);
    try std.testing.expectEqual(@as(f64, 0), fillRect(bar, .{ .state = .normal, .value = -1 }).size.width);
    try std.testing.expect(fillColor(.failed)[0] > fillColor(.normal)[0]);
}
