//! Shaders written once, drawn by every renderer: a small language in
//! Zig's syntax (`parse.zig`), compiled at compile time into HLSL
//! (Direct3D 11), GLSL (OpenGL 3.3, OpenGL ES 3.0 and WebGL 2), Metal and
//! a CPU twin of Zig code (`cpu.zig`) that draws the same pixels, within
//! rounding, where no GPU draws (the CPU renderer, `ui.Tester`). A shader
//! fills a box, through the renderers' backdrop effects (`effect.zig`):
//!
//!     const waves = ui.shader.compile("waves",
//!         \\uniform time: f32;
//!         \\pub fn fragment(pos: vec2) vec4 {
//!         \\    const v = 0.5 + 0.5 * sin(pos.x / 20 + time);
//!         \\    return vec4(v * 0.2, v * 0.4, v, 1);
//!         \\}
//!     );
//!
//!     _ = ui.shaderBox(c, &waves, .{}, .{ .width = .fill, .height = .{ .px = 120 }, .radius = 12 });
//!     c.end();
//!
//! `fragment` returns the pixel's color, premultiplied, which is drawn
//! over what is under the box; `pos` is the point in the box, in points
//! from its top left corner. A uniform the values leave out is zero, but
//! `time` (the context's clock: the box then draws every frame) and
//! `pointer` (where the pointer is, in the box's points).
//!
//! Errors are compile errors, with the shader's line and column:
//! `shader 'waves':3:24: mismatched types i32 and f32`.
//!
//! The language: `uniform name: type;`, `const name = value;` and
//! functions at the top; types `bool`, `i32`, `u32`, `f32`, `vec2`,
//! `vec3`, `vec4`; `const`/`var` locals, assignments (`+=` and the
//! others, components as `v.xy = ...`), `if`/`else`, `while (c) : (i += 1)`,
//! `for (0..n) |i|`, `break`, `continue`, `return`. Numbers without a type
//! take the one their use needs, as Zig's; conversions are `f32(x)`,
//! `i32(x)`, `u32(x)`; vectors are made as `vec3(v.xy, 1)` or `vec3(0)`,
//! a scalar float mixes with vectors, `.xyzw` and `.rgba` swizzle; ints
//! and uints wrap, `<<` `>>` `&` `|` `^` `~` and `%` are theirs, `mod()`
//! the floats'. Builtins: GLSL's (sin, cos, tan, asin, acos, atan, atan2,
//! sinh, cosh, tanh, exp, exp2, log, log2, pow, sqrt, inversesqrt, abs,
//! sign, floor, ceil, fract, round, trunc, mod, min, max, clamp, mix,
//! step, smoothstep, length, distance, dot, cross, normalize, reflect),
//! and `size()` (the box's, in points), `pixel_scale()`, `pixel()` (the
//! pixel's center in the window's pixels) and `backdrop(p)` (what is
//! drawn under the box at its point `p`, blurred by the effect's blur).
//!
//! Uniforms share the effect's sixteen floats: fifteen are theirs (a
//! vec3 takes three), the last holds the pixels a point.
const std = @import("std");
const ir = @import("ir.zig");
const check = @import("check.zig");
const emit = @import("emit.zig");
const effect = @import("../effect.zig");
const types = @import("../types.zig");

pub const Type = ir.Type;
pub const Uniform = ir.UniformInfo;
pub const box = @import("box.zig");

/// A compiled shader: the renderers' effect shader and its uniforms.
pub const Shader = struct {
    effect: effect.Shader,
    uniforms: []const Uniform,

    pub fn uniform(comptime s: *const Shader, comptime name: []const u8) ?Uniform {
        for (s.uniforms) |u| if (std.mem.eql(u8, u.name, name)) return u;
        return null;
    }
};

/// Compiles shader `src` at compile time; `name` tells it apart in logs.
pub fn compile(comptime name: []const u8, comptime src: []const u8) Shader {
    const B = Built(name, src);
    return .{
        .effect = .{ .name = name, .cpu = B.Twin.color, .hlsl = &B.hlsl, .glsl = &B.glsl, .msl = &B.msl },
        .uniforms = &B.uniforms,
    };
}

fn Built(comptime name: []const u8, comptime src: []const u8) type {
    return struct {
        const program: ir.Program = blk: {
            @setEvalBranchQuota(200_000_000);
            var p: ir.Program = undefined;
            check.compile(&p, src) catch {
                const lc = ir.lineCol(src, p.err.at);
                @compileError(std.fmt.comptimePrint("shader '{s}':{d}:{d}: {s}", .{ name, lc[0], lc[1], p.err.text() }));
            };
            break :blk p;
        };
        const hlsl = Text(.hlsl).out.array();
        const glsl = Text(.glsl).out.array();
        const msl = Text(.msl).out.array();
        const Twin = @import("cpu.zig").Twin(&program);
        const uniforms = blk: {
            var list: [program.n_uniforms]Uniform = undefined;
            for (program.uniforms[0..program.n_uniforms], &list) |u, *out| {
                out.* = .{ .name = program.text(u.name), .ty = u.ty, .offset = u.offset };
            }
            break :blk list;
        };

        fn Text(comptime d: emit.Dialect) type {
            return struct {
                const out: emit.Out = o: {
                    @setEvalBranchQuota(200_000_000);
                    var o: emit.Out = .{};
                    emit.emit(&program, d, &o);
                    if (o.over) @compileError("shader '" ++ name ++ "' is too long");
                    break :o o;
                };
            };
        }
    };
}

/// Compiles `src` at run time (for tests of the compiler): the error's
/// message, with line and column, in `msg`, or null.
pub fn checkSource(p: *ir.Program, src: []const u8, msg: []u8) ?[]const u8 {
    check.compile(p, src) catch {
        const lc = ir.lineCol(src, p.err.at);
        return std.fmt.bufPrint(msg, "{d}:{d}: {s}", .{ lc[0], lc[1], p.err.text() }) catch msg;
    };
    return null;
}

/// The effect's parameters for shader `s` with `values` (a struct whose
/// fields are uniforms: numbers, arrays or vectors of floats, `ui.Color`
/// for vec3 and vec4, `ui.Point` for vec2), at `scale` pixels a point.
pub fn params(comptime s: *const Shader, values: anytype, scale: f32) [4][4]f32 {
    const Values = @TypeOf(values);
    var out: [4][4]f32 = @splat(@splat(0));
    const flat: *[16]f32 = @ptrCast(&out);
    inline for (@typeInfo(Values).@"struct".field_names) |field| {
        const u = comptime s.uniform(field) orelse
            @compileError("shader '" ++ s.effect.name ++ "' has no uniform '" ++ field ++ "'");
        set(u, flat, @field(values, field));
    }
    flat[15] = scale;
    return out;
}

/// Sets uniform `u` in `flat` to `v`.
pub fn set(comptime u: Uniform, flat: *[16]f32, v: anytype) void {
    const V = @TypeOf(v);
    const at = u.offset;
    switch (u.ty) {
        .f32 => flat[at] = number(v),
        .bool => flat[at] = if (v) 1 else 0,
        // Integers ride as their bits: every value exact.
        .i32 => flat[at] = @bitCast(@as(i32, @intCast(v))),
        .u32 => flat[at] = @bitCast(@as(u32, @intCast(v))),
        .vec2, .vec3, .vec4 => {
            const n = comptime u.ty.width();
            if (V == types.Color) {
                const c = [4]f32{ v.r, v.g, v.b, v.a };
                inline for (0..n) |k| flat[at + k] = c[k];
            } else if (V == types.Point) {
                if (n != 2) @compileError("a point sets a vec2: '" ++ u.name ++ "'");
                flat[at] = v.x;
                flat[at + 1] = v.y;
            } else {
                inline for (0..n) |k| flat[at + k] = number(v[k]);
            }
        },
        else => unreachable,
    }
}

fn number(v: anytype) f32 {
    return switch (@typeInfo(@TypeOf(v))) {
        .float, .comptime_float => @floatCast(v),
        .int, .comptime_int => @floatFromInt(v),
        else => @compileError("a uniform's number, not a " ++ @typeName(@TypeOf(v))),
    };
}
