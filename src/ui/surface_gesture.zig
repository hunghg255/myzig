//! AppKit scroll and magnification events.
const objc = @import("../objc.zig");
const Surface = @import("surface.zig").Surface;
pub fn scrollWheel(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    s.setMouse(event);
    var dy: f32 = @floatCast(objc.msg(f64, event, "scrollingDeltaY", .{}));
    // A wheel's notches glide (`wheel.zig`); a touchpad follows the fingers.
    const notch = !objc.msg(objc.BOOL, event, "hasPreciseScrollingDeltas", .{});
    if (notch) dy *= 12;
    var dx: f32 = @floatCast(objc.msg(f64, event, "scrollingDeltaX", .{}));
    if (notch) dx *= 12;
    if (@import("gesture.zig").deliver(&s.ctx, .{ .kind = .scroll, .dx = -dx, .dy = -dy, .precise = !notch })) {
        s.frame();
        return;
    }
    if (if (notch) s.ctx.applyWheel(dy) else s.ctx.applyScroll(dy)) {
        s.frame();
        s.ctx.updateHot();
    } else if (s.ctx.wants_wheel) {
        s.ctx.input.scroll = .{ .y = dy };
        s.frame();
    }
}

pub fn magnify(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    s.setMouse(event);
    const scale: f32 = @floatCast(1 + objc.msg(f64, event, "magnification", .{}));
    if (@import("gesture.zig").deliver(&s.ctx, .{ .kind = .zoom, .scale = scale })) s.frame();
}
