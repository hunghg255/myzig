//! Backdrop effects (`Style.effect`): a box that draws from what is drawn
//! under it, frosted glass and the like, under its own children. Paint
//! marks where the effect draws in paint order (`gpu.Kind.effect`), and
//! each renderer, at the mark, reads what it drew so far around the shape,
//! blurs it (`backdrop.zig`: averaged down for large blurs, then a Gaussian
//! along rows and columns), and draws the box from it, with the effect's
//! shader or as it is, before drawing on. The CPU renderer runs the
//! shader's CPU twin (`Shader.cpu`); the GPUs run its HLSL, GLSL or Metal
//! source, which they compile once.
//!
//!     const frost: ui.Effect = .{ .blur = 12 };
//!     _ = c.open(.{ .effect = &frost, .radius = 16, .padding = .all(12) }, null);
//!
//! A shader is a function of the pixel, its shape and the blurred
//! backdrop, which it samples anywhere (a lens bends what shows through):
//!
//!     HLSL, GLSL:  float3 effect_color(EffectIn i)  (vec3 in GLSL)
//!     Metal:       float3 effect_color(EffectIn i, texture2d<float> backdrop)
//!
//! where `EffectIn` holds `p` (the pixel's center, in the frame's pixels),
//! `rect` (x, y, w, h) and `radius` of the shape in pixels, and `params`
//! (four float4s); `backdrop_at(i, p)` (Metal: `backdrop_at(i, backdrop,
//! p)`) samples the backdrop there, premultiplied, as `Input.sample` does.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const Backdrop = @import("backdrop.zig").Backdrop;

pub const Effect = struct {
    /// How much what is under the box blurs: a standard deviation, in
    /// points (CSS's backdrop-filter: blur()).
    blur: f32 = 0,
    /// What the box draws from the blurred backdrop; null shows it as it is.
    shader: ?*const Shader = null,
    /// The shader's parameters, as it reads them.
    params: [4][4]f32 = @splat(.{ 0, 0, 0, 0 }),
};

pub const Shader = struct {
    /// Tells shaders apart: each renderer compiles one once.
    name: []const u8,
    /// The CPU twin: the effect's color (premultiplied, opaque) at a pixel.
    cpu: *const fn (in: *const Input) [3]f32,
    hlsl: []const u8 = "",
    glsl: []const u8 = "",
    msl: []const u8 = "",
};

/// What a shader's CPU twin gets for a pixel.
pub const Input = struct {
    /// The pixel's center, in the frame's pixels.
    p: [2]f32,
    /// The shape (x, y, w, h) and its corners' radius, in pixels.
    rect: [4]f32,
    radius: f32,
    params: *const [4][4]f32,
    backdrop: *const Backdrop,

    /// The blurred backdrop at (x, y), in the frame's pixels.
    pub fn sample(in: *const Input, x: f32, y: f32) [3]f32 {
        return in.backdrop.sample(x, y);
    }
};

/// Rows of an effect's mark: the blur and the shader (its address, in
/// three exact parts), then its parameters.
pub const rows_per_effect = 5;

pub fn encode(e: *const Effect) [rows_per_effect][4]f32 {
    const a: usize = if (e.shader) |s| @intFromPtr(s) else 0;
    const w: u64 = a;
    var out: [rows_per_effect][4]f32 = undefined;
    out[0] = .{ e.blur, @floatFromInt(w & 0xffffff), @floatFromInt((w >> 24) & 0xffffff), @floatFromInt(w >> 48) };
    for (e.params, 1..) |p, k| out[k] = p;
    return out;
}

/// The shader of the effect whose rows start at `row`, if it has one.
pub fn shaderOf(rows: []const [4]f32, row: usize) ?*const Shader {
    if (row + rows_per_effect > rows.len) return null;
    const r = rows[row];
    const w: u64 = @as(u64, @intFromFloat(r[1])) | @as(u64, @intFromFloat(r[2])) << 24 | @as(u64, @intFromFloat(r[3])) << 48;
    if (w == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(w)));
}

pub fn paramsOf(rows: []const [4]f32, row: usize) *const [4][4]f32 {
    return @ptrCast(rows[row + 1 ..][0..4]);
}

/// Paints a box's effect mark, in place of its background.
pub fn paint(p: anytype, e: *const Effect, st: *const types.Style, rect4: [4]f32, clip4: [4]f32) void {
    const c = p.c;
    const row: u32 = @intCast(p.rows.items.len);
    p.rows.appendSlice(c.alloc(), &encode(e)) catch return;
    p.out.append(c.gpa, .{
        .rect = rect4,
        .color = .{ 0, 0, 0, 0 },
        .radius = st.radius,
        .uv = .{ @floatFromInt(row), 0, 0, 0 },
        .kind = gpu.Kind.effect,
        .clip = clip4,
    }) catch {};
}

/// Opens a blurred layer over `rect4` (the box grown by its blur's reach):
/// what follows until `endLayer` draws into it.
pub fn beginLayer(p: anytype, sigma: f32, rect4: [4]f32, clip4: [4]f32) void {
    const reach = 3 * sigma;
    p.out.append(p.c.gpa, .{
        .rect = .{ rect4[0] - reach, rect4[1] - reach, rect4[2] + 2 * reach, rect4[3] + 2 * reach },
        .color = .{ 0, 0, 0, 0 },
        .border_width = sigma,
        .kind = gpu.Kind.layer,
        .clip = clip4,
    }) catch {};
}

pub fn endLayer(p: anytype, sigma: f32, rect4: [4]f32, clip4: [4]f32) void {
    const reach = 3 * sigma;
    p.out.append(p.c.gpa, .{
        .rect = .{ rect4[0] - reach, rect4[1] - reach, rect4[2] + 2 * reach, rect4[3] + 2 * reach },
        .color = .{ 0, 0, 0, 0 },
        .border_width = sigma,
        .kind = gpu.Kind.layer_end,
        .clip = clip4,
    }) catch {};
}

test "an effect's shader rides in its rows" {
    const S = struct {
        fn color(_: *const Input) [3]f32 {
            return .{ 1, 0, 0 };
        }
        const shader: Shader = .{ .name = "red", .cpu = color };
    };
    const e: Effect = .{ .blur = 4, .shader = &S.shader, .params = .{ .{ 1, 2, 3, 4 }, @splat(0), @splat(0), .{ 0, 0, 0, 9 } } };
    const rows = encode(&e);
    try std.testing.expectEqual(&S.shader, shaderOf(&rows, 0).?);
    try std.testing.expectEqual(@as(f32, 9), paramsOf(&rows, 0)[3][3]);
    try std.testing.expect(shaderOf(&encode(&.{}), 0) == null);
}
