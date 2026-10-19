//! The shader compiler's tests: what it accepts, the errors it reports
//! (with line and column), the code it writes, and the CPU twin's values.
const std = @import("std");
const testing = std.testing;
const ir = @import("ir.zig");
const shader = @import("shader.zig");
const effect = @import("../effect.zig");
const Backdrop = @import("../backdrop.zig").Backdrop;

fn errorOf(src: []const u8) ![]const u8 {
    const p = try testing.allocator.create(ir.Program);
    defer testing.allocator.destroy(p);
    const S = struct {
        var msg: [256]u8 = undefined;
    };
    const m = shader.checkSource(p, src, &S.msg) orelse return error.Compiled;
    return m;
}

fn expectError(src: []const u8, want: []const u8) !void {
    const got = try errorOf(src);
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("expected an error with \"{s}\", got \"{s}\"\n", .{ want, got });
        return error.TestUnexpectedError;
    }
}

const frag = "pub fn fragment(pos: vec2) vec4 { return vec4(0); }\n";

test "type errors, with where they are" {
    try expectError("pub fn fragment(pos: vec2) vec4 {\n    const a: i32 = 1;\n    return vec4(a);\n}", "3:12: vec4() is made of floats and vectors, not a i32");
    try expectError("pub fn fragment(pos: vec2) vec4 {\n    const a: i32 = 1;\n    const b = a + 0.5;\n    return vec4(b);\n}", "'0.5' is not an integer");
    try expectError("pub fn fragment(pos: vec2) vec4 { const x = pos.z; return vec4(x); }", "a vec2 has no component 'z'");
    try expectError("pub fn fragment(pos: vec2) vec4 { const x = 1.0; x = 2.0; return vec4(x); }", "'x' is a constant");
    try expectError("pub fn fragment(pos: vec2) vec4 { return vec4(nope); }", "'nope' is not declared");
    try expectError("fn f(x: f32) f32 { if (x > 0) { return 1; } }\n" ++ frag, "'f' must end by returning a f32");
    try expectError("fn f(x: f32) f32 { return f(x); }\npub fn fragment(pos: vec2) vec4 { return vec4(f(1)); }", "'f' calls itself");
    try expectError("pub fn fragment(pos: vec2) vec4 { const x: f32 = 1 / 2; return vec4(x); }", "integer division of constants");
    try expectError("pub fn fragment(pos: vec2) vec4 { return mix(vec3(0), vec4(1), 0.5); }", "mix() of a vec3 and a vec4");
    try expectError("pub fn fragment(pos: vec2) f32 { return 1; }", "'fragment' is 'fn fragment(pos: vec2) vec4'");
    try expectError("uniform a: vec4;\nuniform b: vec4;\nuniform c: vec4;\nuniform d: vec4;\n" ++ frag, "4:9: the uniforms take more than 15 floats");
    try expectError("pub fn fragment(pos: vec2) vec4 { var u: u32 = 5000000000; return vec4(f32(u)); }", "does not fit in a u32");
    try expectError("pub fn fragment(pos: vec2) vec4 { if (1 < 2 < 3) { } return vec4(0); }", "comparisons don't chain");
    try expectError("pub fn fragment(pos: vec2) vec4 { break; }", "'break' outside of a loop");
    try expectError("pub fn fragment(pos: vec2) vec4 { const pos = 1.0; return vec4(pos); }", "'pos' shadows");
    try expectError("pub fn fragment(pos: vec2) vec4 { return vec4(1) % 2.0; }", "use mod(a, b)");
    try expectError("fn f() vec4 { return vec4(0); }", "a shader needs 'pub fn fragment");
}

test "what it accepts" {
    const src =
        \\uniform time: f32;
        \\uniform seed: u32;
        \\uniform tint: vec3;
        \\const tau = 6.2831853;
        \\const k: f32 = tau / 4;
        \\fn pcg(v: u32) u32 {
        \\    const s = v * 747796405 + 2891336453;
        \\    const w = ((s >> ((s >> 28) + 4)) ^ s) * 277803737;
        \\    return (w >> 22) ^ w;
        \\}
        \\fn paint(c: vec3) void { }
        \\pub fn fragment(pos: vec2) vec4 {
        \\    var c = vec3(0);
        \\    c.xy = pos / size();
        \\    c.z += 0.5;
        \\    var i: i32 = 0;
        \\    while (i < 3) : (i += 1) { c *= 0.9; if (i == 1) { continue; } }
        \\    for (0..2) |j| { c += f32(j) * 0.01; }
        \\    const h = f32(pcg(seed ^ u32(i32(pos.x))) >> 8) / 16777216.0;
        \\    paint(c);
        \\    return vec4(mix(c, tint, h) * sin(time * k), 1);
        \\}
    ;
    const p = try testing.allocator.create(ir.Program);
    defer testing.allocator.destroy(p);
    var msg: [256]u8 = undefined;
    if (shader.checkSource(p, src, &msg)) |m| {
        std.debug.print("{s}\n", .{m});
        return error.TestUnexpectedError;
    }
    try testing.expectEqual(@as(u8, 2), p.uniforms[2].offset);
}

const gradient = shader.compile("test-gradient",
    \\uniform tint: vec4;
    \\uniform k: i32;
    \\pub fn fragment(pos: vec2) vec4 {
    \\    const t = pos.x / size().x;
    \\    var c = mix(vec3(1, 0, 0), tint.rgb, t);
    \\    if (k > 1) {
    \\        c = c.bgr;
    \\    }
    \\    return vec4(c, 1) * tint.a;
    \\}
);

test "the code each backend gets" {
    try testing.expect(std.mem.indexOf(u8, gradient.effect.hlsl, "float3 effect_color(EffectIn _i)") != null);
    try testing.expect(std.mem.indexOf(u8, gradient.effect.hlsl, "lerp(") != null);
    try testing.expect(std.mem.indexOf(u8, gradient.effect.glsl, "vec3 effect_color(EffectIn _i)") != null);
    try testing.expect(std.mem.indexOf(u8, gradient.effect.glsl, "floatBitsToInt(_i.params[1].x)") != null);
    try testing.expect(std.mem.indexOf(u8, gradient.effect.msl, "static float3 effect_color(EffectIn _i, texture2d<float> _bd)") != null);
    try testing.expectEqual(@as(usize, 2), gradient.uniforms.len);
    try testing.expectEqualStrings("k", gradient.uniforms[1].name);
}

/// A backdrop of one color, `w`×`h` pixels.
fn plain(gpa: std.mem.Allocator, w: usize, h: usize, c: [3]f32) !Backdrop {
    var b: Backdrop = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h, .down = 1, .sigma = 0, .radius = 0, .w = w, .h = h };
    b.pix = try gpa.alloc(f32, 4 * w * h);
    for (0..w * h) |i| b.pix[4 * i ..][0..4].* = .{ c[0], c[1], c[2], 1 };
    return b;
}

test "the CPU twin: uniforms, the box's points, over the backdrop" {
    var b = try plain(testing.allocator, 100, 50, .{ 0, 0, 1 });
    defer b.deinit(testing.allocator);
    const values = shader.params(&gradient, .{ .tint = [4]f32{ 0, 1, 0, 0.5 }, .k = 0 }, 2);
    var in: effect.Input = .{ .p = .{ 10.5, 20.5 }, .rect = .{ 10, 20, 80, 20 }, .radius = 0, .params = &values, .backdrop = &b };
    // At the left edge: red at half, over blue.
    const left = gradient.effect.cpu(&in);
    try testing.expectApproxEqAbs(@as(f32, 0.5), left[0], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.5), left[2], 0.01);
    in.p = .{ 89.5, 20.5 };
    const right = gradient.effect.cpu(&in);
    try testing.expectApproxEqAbs(@as(f32, 0.5), right[1], 0.01);
    // k swaps red and blue.
    const swapped = shader.params(&gradient, .{ .tint = [4]f32{ 0, 1, 0, 1 }, .k = 2 }, 2);
    in.params = &swapped;
    in.p = .{ 10.5, 20.5 };
    try testing.expectApproxEqAbs(@as(f32, 1), gradient.effect.cpu(&in)[2], 0.01);
}

const ints = shader.compile("test-ints",
    \\uniform seed: u32;
    \\fn pcg(v: u32) u32 {
    \\    const s = v * 747796405 + 2891336453;
    \\    const w = ((s >> ((s >> 28) + 4)) ^ s) * 277803737;
    \\    return (w >> 22) ^ w;
    \\}
    \\pub fn fragment() vec4 {
    \\    const h = pcg(seed);
    \\    var n: i32 = -7;
    \\    n = n / 2 + n % 3;
    \\    return vec4(f32(h & 255) / 255.0, f32(h >> 24) / 255.0, f32(n + 10) / 10.0, 1);
    \\}
);

fn pcg(v: u32) u32 {
    const s = v *% 747796405 +% 2891336453;
    const w = ((s >> @intCast((s >> 28) + 4)) ^ s) *% 277803737;
    return (w >> 22) ^ w;
}

test "the CPU twin's integers wrap, as the GPUs' do" {
    var b = try plain(testing.allocator, 4, 4, .{ 0, 0, 0 });
    defer b.deinit(testing.allocator);
    const values = shader.params(&ints, .{ .seed = 0xdeadbeef }, 1);
    const in: effect.Input = .{ .p = .{ 1.5, 1.5 }, .rect = .{ 0, 0, 4, 4 }, .radius = 0, .params = &values, .backdrop = &b };
    const c = ints.effect.cpu(&in);
    const h = pcg(0xdeadbeef);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(h & 255)) / 255, c[0], 0.003);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(h >> 24)) / 255, c[1], 0.003);
    // -7 / 2 + -7 % 3 = -3 + -1, truncating as C and Direct3D do.
    try testing.expectApproxEqAbs(@as(f32, 0.6), c[2], 0.003);
}
