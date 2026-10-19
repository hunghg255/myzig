//! The glass as a backdrop effect of myzig's renderers (`Style.effect`):
//! its material packed as the effect's parameters, its color on the GPU
//! (`glass.hlsl`, `glass.glsl`, `glass.metal`) and on the CPU (`pixels.zig`,
//! the twin), which each renderer draws from the backdrop it read and
//! blurred under the pane, before the pane's children.
const std = @import("std");
const ui = @import("myzig").ui;
const material = @import("material.zig");
const pixels = @import("pixels.zig");

/// myzig's effect types (src/ui/effect.zig), as `ui.Style` names them.
pub const Effect = @typeInfo(@typeInfo(@FieldType(ui.Style, "effect")).optional.child).pointer.child;
pub const Shader = @typeInfo(@typeInfo(@FieldType(Effect, "shader")).optional.child).pointer.child;
pub const Input = @typeInfo(@typeInfo(@typeInfo(@FieldType(Shader, "cpu")).pointer.child).@"fn".param_types[0].?).pointer.child;

pub const glass: Shader = .{
    .name = "myzig-glass",
    .cpu = cpu,
    .hlsl = @embedFile("glass.hlsl"),
    .glsl = @embedFile("glass.glsl"),
    .msl = @embedFile("glass.metal"),
};

/// The effect of material `m` (in pixels) at `scale` pixels a point: its
/// blur, in points, and its parameters as the shaders read them.
pub fn effectOf(m: material.Material, scale: f32) Effect {
    return .{
        .blur = m.blur / scale,
        .shader = &glass,
        .params = .{
            .{ m.bezel, m.refraction, m.rim, m.rim_width },
            m.tint,
            .{ m.low, m.high, m.curve, m.saturation },
            .{ @cos(m.light), @sin(m.light), 0, 0 },
        },
    };
}

/// A plain backdrop blur of `sigma` points: the backdrop as it is.
pub fn blurOf(sigma: f32) Effect {
    return .{ .blur = sigma };
}

/// The material the parameters hold.
fn materialOf(p: *const [4][4]f32) material.Material {
    return .{
        .blur = 0,
        .bezel = p[0][0],
        .refraction = p[0][1],
        .rim = p[0][2],
        .rim_width = p[0][3],
        .tint = p[1],
        .low = p[2][0],
        .high = p[2][1],
        .curve = p[2][2],
        .saturation = p[2][3],
        .light = std.math.atan2(p[3][1], p[3][0]),
    };
}

/// The CPU twin: the glass's color at a pixel.
fn cpu(in: *const Input) [3]f32 {
    const m = materialOf(in.params);
    return pixels.glassColor(&m, in.rect, @splat(in.radius), in.p[0], in.p[1], in);
}
