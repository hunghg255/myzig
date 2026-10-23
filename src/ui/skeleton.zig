//! Decorative placeholders while real content is loading.
const std = @import("std");
const types = @import("types.zig");
const motion = @import("motion.zig");
const Context = @import("context.zig").Context;

pub const Options = struct {
    width: types.Length = .fill,
    height: f32 = 16,
    radius: f32 = 6,
    animated: bool = true,
};

/// A placeholder takes no focus and exposes no fictitious content to
/// assistive technology. Name the surrounding group if it needs a status.
pub fn skeleton(c: *Context, opts: Options) void {
    var opacity: f32 = 1;
    if (opts.animated and !motion.reduced(c)) {
        opacity = 0.75 + 0.25 * @as(f32, @floatCast(@cos(c.time * 2 * std.math.pi / 1.6)));
        c.frameIn(1.0 / 30.0);
    }
    const index = c.leaf(.{
        .width = opts.width,
        .height = .{ .px = @max(0, opts.height) },
        .radius = @max(0, opts.radius),
        .background = c.theme.track.alpha(opacity),
    }, .none, null);
    c.describe(c.node(index).id, .{ .role = .none });
}
