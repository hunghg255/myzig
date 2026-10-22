//! The first visible maximize button of a frame, for Windows Snap Layouts.
const Context = @import("context.zig").Context;
const Rect = @import("types.zig").Rect;

pub fn rect(c: *const Context) ?Rect {
    for (c.hits.items) |hit| {
        if (hit.index >= c.nodes.items.len) continue;
        if (!c.nodes.items[hit.index].maximize_button) continue;
        // Snap hit testing uses an axis-aligned client rectangle.
        if (hit.inverse != null or hit.rect.w <= 0 or hit.rect.h <= 0) continue;
        const visible = hit.rect.intersect(.{ .w = c.size.w, .h = c.size.h });
        if (visible.w > 0 and visible.h > 0) return visible;
    }
    return null;
}

pub fn update(c: *Context) void {
    if (comptime @import("builtin").os.tag != .windows) return;
    const host = c.host orelse return;
    const window: *@import("../windows/window.zig").Window = @ptrCast(@alignCast(host));
    if (window.title_bar != .hidden or !window.hide_window_buttons) return;
    const r = rect(c);
    window.setSnapButton(if (r) |v| .{ .x = v.x, .y = v.y, .width = v.w, .height = v.h } else null);
}
