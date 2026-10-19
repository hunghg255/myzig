//! Shaders on the GPUs: each backend's code compiles in the renderer's
//! effect pass (HLSL with Direct3D's compiler on Windows, GLSL with Mesa
//! through EGL on Linux; Metal is checked on macOS), and the GPUs draw
//! views of shader boxes as the CPU twin does, within a level or two.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const ui = @import("../ui.zig");
const fx = @import("../gpu_fx_test.zig");
const box = @import("box.zig");
const shader = @import("shader.zig");
const shaders = @import("tests_shaders.zig");

/// `d3d11_fx.zig`'s entry point of the effect pass.
const hlsl_main =
    \\
    \\float4 effect_ps(VOut v) : SV_Target {
    \\    EffectIn i = effect_in(v);
    \\    float cov = effect_cover(i);
    \\    if (cov <= 0.0) discard;
    \\    float3 c = floor(saturate(effect_color(i)) * 255.0 + 0.5) / 255.0;
    \\    return float4(c * cov, cov);
    \\}
;

test "every test shader's HLSL compiles in Direct3D's effect pass" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const d3d = @import("../d3d11_api.zig");
    const gpa = testing.allocator;
    for (shaders.all) |s| {
        const src = try std.mem.concat(gpa, u8, &.{ @embedFile("../d3d11_fx.hlsl"), "\n", s.effect.hlsl, hlsl_main });
        defer gpa.free(src);
        const code = d3d.compile(gpa, src, "effect_ps", "ps_4_0") catch |e| {
            if (e == error.NoShaderCompiler) return error.SkipZigTest;
            std.debug.print("{s}:\n{s}\n", .{ s.effect.name, s.effect.hlsl });
            return e;
        };
        gpa.free(code);
    }
}

test "every test shader's GLSL compiles for OpenGL 3.3 and OpenGL ES 3.0" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gl = @import("../gl_api.zig");
    const gl_fx = @import("../gl_fx.zig");
    for ([_]bool{ false, true }) |es| {
        var o = @import("../gl_offscreen.zig").Offscreen.init(es) catch return error.SkipZigTest;
        defer o.deinit();
        if (!gl.load()) return error.SkipZigTest;
        const g = &gl.api;
        for (shaders.all) |s| {
            const parts = [_][]const u8{ if (es) "#version 300 es\n" else "#version 330 core\n", "#define EFFECT 1\n", gl_fx.source, s.effect.glsl, gl_fx.effect_main };
            var ptrs: [parts.len][*]const u8 = undefined;
            var lens: [parts.len]i32 = undefined;
            for (parts, 0..) |part, k| {
                ptrs[k] = part.ptr;
                lens[k] = @intCast(part.len);
            }
            const id = g.glCreateShader(gl.fragment_shader);
            defer g.glDeleteShader(id);
            g.glShaderSource(id, parts.len, &ptrs, &lens);
            g.glCompileShader(id);
            var ok: i32 = 0;
            g.glGetShaderiv(id, gl.compile_status, &ok);
            if (ok == 0) {
                var buf: [4096]u8 = @splat(0);
                g.glGetShaderInfoLog(id, buf.len, null, &buf);
                std.debug.print("{s} ({s}): {s}\n{s}\n", .{ s.effect.name, if (es) "es" else "gl", std.mem.sliceTo(&buf, 0), s.effect.glsl });
                return error.ShaderCompile;
            }
        }
    }
}

/// Stripes under the shader boxes, which read the backdrop and draw over it.
const Scene = struct {
    time: f32 = 1.25,

    fn view(s: *Scene, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(12), .gap = 8, .width = .fill, .height = .fill });
        defer ui.end(c);
        {
            _ = c.open(.{ .direction = .row, .height = .{ .px = 90 }, .width = .fill }, null);
            defer c.end();
            for (0..36) |k| {
                const col: ui.Color = if (k % 3 == 0) .hex(0xe0401a) else if (k % 3 == 1) .white else .hex(0x1a4ce0);
                _ = c.open(.{ .width = .{ .px = 8 }, .height = .fill, .background = col }, null);
                c.end();
            }
            _ = box.shaderBox(c, &shaders.rings, .{ .time = s.time, .tint = ui.Color{ .r = 0.1, .g = 0.3, .b = 0.9, .a = 0.8 }, .center = .{ 0.4, 0.5 } }, .{ .absolute = true, .offset = .{ .x = 10, .y = 8 }, .width = .{ .px = 120 }, .height = .{ .px = 70 }, .radius = 14 });
            c.end();
            _ = box.shaderBoxWith(c, &shaders.lens, .{ .strength = 0.35, .tint = ui.Color.white, .frosted = true }, .{ .absolute = true, .offset = .{ .x = 150, .y = 5 }, .width = .{ .px = 80 }, .height = .{ .px = 80 }, .radius = 40 }, .{ .blur = 1.5 });
            c.end();
        }
        _ = box.shaderBox(c, &shaders.noise, .{ .seed = 0x9e3779b9, .octaves = 4, .scale = 18 }, .{ .width = .fill, .height = .{ .px = 60 }, .radius = 8 });
        c.end();
        _ = box.shaderBox(c, &shaders.ring, .{ .time = s.time, .strength = 0.8, .pad = 10, .radius = 14 }, .{ .width = .fill, .height = .{ .px = 64 }, .padding = .all(18) });
        ui.text(c, "Ask anything", .{ .size = 13 });
        c.end();
    }
};

fn compare(d: fx.Draw) !void {
    var s: Scene = .{};
    try fx.compareView(d, .init(&s, Scene.view), 300, 280);
}

test "Direct3D draws shader boxes as the CPU twin does" {
    try fx.withD3d(compare);
}

test "OpenGL draws shader boxes as the CPU twin does" {
    try fx.withGl(false, compare);
}

test "OpenGL ES draws shader boxes as the CPU twin does" {
    try fx.withGl(true, compare);
}
