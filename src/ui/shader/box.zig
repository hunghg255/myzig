//! Shaders in views: a box filled by a shader (`shaderBox`), or a shader
//! as a backdrop effect for any box's style (`effectOf`), drawn by the
//! renderers' effect pass (`effect.zig`) from the effect's parameters,
//! which the uniforms' values are packed into each frame.
const std = @import("std");
const effect = @import("../effect.zig");
const types = @import("../types.zig");
const Context = @import("../context.zig").Context;
const shader = @import("shader.zig");

pub const Options = struct {
    /// What is under the box blurs by this much before the shader reads
    /// it (`backdrop(p)`) and draws over it: a standard deviation, in points.
    blur: f32 = 0,
};

/// An effect drawing shader `s` with `values` (see `shader.params`),
/// allocated for this frame: for `Style.effect`. A `time` uniform left
/// out is the context's clock (and the view animates), a `pointer` one
/// the pointer, in the points of the box whose rect was `last`.
pub fn effectOf(c: *Context, comptime s: *const shader.Shader, values: anytype, last: ?types.Rect, opts: Options) *const effect.Effect {
    const e = c.alloc().create(effect.Effect) catch return &none;
    e.* = .{ .blur = opts.blur, .shader = &s.effect, .params = shader.params(s, values, c.scale) };
    const flat: *[16]f32 = @ptrCast(&e.params);
    const Values = @TypeOf(values);
    if (comptime s.uniform("time")) |u| {
        if (!@hasField(Values, "time") and u.ty == .f32) {
            flat[u.offset] = @floatCast(c.time);
            c.animationFrame();
        }
    }
    if (comptime s.uniform("pointer")) |u| {
        if (!@hasField(Values, "pointer") and u.ty == .vec2) {
            const r = last orelse types.Rect{};
            flat[u.offset] = c.input.mouse.x - r.x;
            flat[u.offset + 1] = c.input.mouse.y - r.y;
        }
    }
    return e;
}

const none: effect.Effect = .{};

/// Opens a box styled by `style` and filled by shader `s` with `values`,
/// which replaces its background (the renderers draw a box's background
/// over its effect); its children follow until `c.end()`.
pub fn shaderBox(c: *Context, comptime s: *const shader.Shader, values: anytype, style: types.Style) u32 {
    return shaderBoxWith(c, s, values, style, .{});
}

pub fn shaderBoxWith(c: *Context, comptime s: *const shader.Shader, values: anytype, style_in: types.Style, opts: Options) u32 {
    var style = style_in;
    style.background = null;
    style.effect = effectOf(c, s, values, c.rects.get(c.peekId(null)), opts);
    return c.open(style, null);
}
