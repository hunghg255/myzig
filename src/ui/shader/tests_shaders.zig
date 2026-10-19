//! Shaders the GPU tests draw (`tests_gpu.zig`): between them every part
//! of the language, hashes of uints, noise, loops that break, branches,
//! uniforms of every type and the backdrop, read where the box is and
//! around.
const shader = @import("shader.zig");

/// Rings that move with time, a gradient across, translucent over the backdrop.
pub const rings = shader.compile("test-rings",
    \\uniform time: f32;
    \\uniform tint: vec4;
    \\uniform center: vec2;
    \\pub fn fragment(pos: vec2) vec4 {
    \\    const d = distance(pos, center * size());
    \\    const v = 0.5 + 0.5 * sin(d / 3 - time * 2);
    \\    const c = mix(tint.rgb, vec3(1, 0.8, 0.2), pos.x / size().x);
    \\    const a = clamp(v * tint.a, 0, 1);
    \\    return vec4(c * a, a);
    \\}
);

/// Value noise of hashed uints, a loop of octaves, a seed and a count.
pub const noise = shader.compile("test-noise",
    \\uniform seed: u32;
    \\uniform octaves: i32;
    \\uniform scale: f32;
    \\fn pcg(v: u32) u32 {
    \\    const s = v * 747796405 + 2891336453;
    \\    const w = ((s >> ((s >> 28) + 4)) ^ s) * 277803737;
    \\    return (w >> 22) ^ w;
    \\}
    \\fn hash(p: vec2) f32 {
    \\    const h = pcg(u32(i32(p.x)) ^ pcg(u32(i32(p.y)) ^ seed));
    \\    return f32(h >> 8) * (1.0 / 16777216.0);
    \\}
    \\fn value(p: vec2) f32 {
    \\    const i = floor(p);
    \\    var f = fract(p);
    \\    f = f * f * (3 - 2 * f);
    \\    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
    \\}
    \\pub fn fragment(pos: vec2) vec4 {
    \\    var p = pos / scale + 100;
    \\    var s = 0.0;
    \\    var a = 0.5;
    \\    var i: i32 = 0;
    \\    while (true) : (i += 1) {
    \\        if (i >= octaves) {
    \\            break;
    \\        }
    \\        s += a * value(p);
    \\        p = p * 2.03 + 17.1;
    \\        a *= 0.5;
    \\    }
    \\    const g = smoothstep(0.3, 0.7, s);
    \\    return vec4(g * 0.9, g * g * 0.6 + 0.1, 1 - g * 0.8, 1);
    \\}
);

/// The backdrop, bent as by a lens and tinted: what a pane of glass does.
pub const lens = shader.compile("test-lens",
    \\uniform strength: f32;
    \\uniform tint: vec3;
    \\uniform frosted: bool;
    \\pub fn fragment(pos: vec2) vec4 {
    \\    const mid = size() * 0.5;
    \\    const q = (pos - mid) / mid;
    \\    const r = length(q);
    \\    var at = pos;
    \\    if (r < 1) {
    \\        at = mid + (pos - mid) * (1 - strength * (1 - r * r));
    \\    }
    \\    var c = backdrop(at).rgb;
    \\    if (frosted) {
    \\        c = mix(c, tint, 0.25);
    \\    }
    \\    // Darker toward the edge, a rim of light.
    \\    c *= 1 - 0.3 * smoothstep(0.6, 1.0, r);
    \\    c += vec3(0.15) * exp(-abs(r - 0.95) * 30);
    \\    return vec4(c, 1);
    \\}
);

/// A chat ring, after mygo's chat-glow: a rounded rectangle's outline
/// glowing outward, its colors flowing around (the palette in branches).
pub const ring = shader.compile("test-ring",
    \\uniform time: f32;
    \\uniform strength: f32;
    \\uniform pad: f32;
    \\uniform radius: f32;
    \\fn palette(x0: f32) vec3 {
    \\    const x = fract(x0) * 3;
    \\    if (x < 1) {
    \\        return mix(vec3(0.74, 0.51, 0.95), vec3(0.96, 0.73, 0.92), x);
    \\    } else if (x < 2) {
    \\        return mix(vec3(0.96, 0.73, 0.92), vec3(0.55, 0.62, 1), x - 1);
    \\    }
    \\    return mix(vec3(0.55, 0.62, 1), vec3(0.74, 0.51, 0.95), x - 2);
    \\}
    \\fn round_rect(p: vec2, half: vec2, r: f32) f32 {
    \\    const q = abs(p) - half + r;
    \\    return length(max(q, 0)) + min(max(q.x, q.y), 0) - r;
    \\}
    \\pub fn fragment(pos: vec2) vec4 {
    \\    const box = size();
    \\    const p = pos - 0.5 * box;
    \\    const d = round_rect(p, 0.5 * box - pad, radius) - 0.6;
    \\    const a0 = atan2(p.y / box.y, p.x / box.x) / 6.2831853 + 0.5;
    \\    const line = exp(-abs(d) / 0.9);
    \\    var glow = 0.0;
    \\    if (d > 0) {
    \\        glow = (exp(-d / 6) * 0.55 + exp(-d / 16) * 0.25) * smoothstep(pad, pad * 0.3, d);
    \\    }
    \\    const alpha = clamp(line * (0.5 + 0.5 * strength) + glow * strength, 0, 1);
    \\    const col = mix(palette(a0 + time * 0.12), palette(a0 + time * 0.12 + 0.2), glow / (line + glow + 0.0001));
    \\    return vec4(col * alpha, alpha);
    \\}
);

pub const all = [_]*const shader.Shader{ &rings, &noise, &lens, &ring };
