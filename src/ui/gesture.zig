//! Scroll and pinch input, delivered to the innermost handler before scrolling.
const std = @import("std");
const Context = @import("context.zig").Context;
const none = @import("node.zig").none;

pub const InputEvent = struct {
    kind: enum { scroll, zoom },
    /// Pointer in points relative to the element.
    x: f32 = 0,
    y: f32 = 0,
    /// Scroll in points, positive down/right. Zoom is a multiplicative scale.
    dx: f32 = 0,
    dy: f32 = 0,
    scale: f32 = 1,
    precise: bool = true,
    ctrl: bool = false,
    shift: bool = false,
    cmd: bool = false,
};

pub const Handler = struct {
    ptr: *anyopaque,
    call: *const fn (*anyopaque, InputEvent) bool,
    inverse: @import("types.zig").Affine = .{},
};

pub fn deliver(c: *Context, event: InputEvent) bool {
    if (!@import("types.zig").Rect.contains(.{ .w = c.size.w, .h = c.size.h }, c.input.mouse)) return false;
    if (event.kind == .zoom and (!std.math.isFinite(event.scale) or event.scale <= 0 or event.scale == 1)) return false;
    var i = c.hits.items.len;
    while (i > 0) {
        i -= 1;
        const hit = c.hits.items[i];
        if (!hit.contains(c.input.mouse)) continue;
        var at = hit.index;
        while (at != none and at < c.nodes.items.len) {
            const n = c.nodes.items[at];
            if (n.input_handler) |h| {
                var e = event;
                const point = h.inverse.apply(c.input.mouse);
                e.x = point.x - n.rect.x;
                e.y = point.y - n.rect.y;
                e.ctrl = c.input.ctrl;
                e.shift = c.input.shift;
                e.cmd = c.input.cmd;
                if (h.call(h.ptr, e)) return true;
            }
            at = n.parent;
        }
        return false;
    }
    return false;
}

pub fn pinch(c: *Context, x: f32, y: f32, scale: f32) bool {
    c.input.mouse = .{ .x = x, .y = y };
    return deliver(c, .{ .kind = .zoom, .scale = scale });
}
