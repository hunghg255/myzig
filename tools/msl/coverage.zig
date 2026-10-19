//! A shader for the MSL check alone (`check.zig`): every builtin of the
//! shader language in its scalar and vector forms, integers of both
//! signs, uniforms of every type (vectors across two of the effect's
//! float4s), every operator and statement, so the emitter's Metal is
//! checked for what the examples don't happen to use.
const ui = @import("myzig").ui;

pub const shader = ui.shader.compile("msl-coverage",
    \\uniform f: f32;
    \\uniform v2: vec2;
    \\uniform v3: vec3;
    \\uniform v4: vec4;
    \\uniform n: i32;
    \\uniform u: u32;
    \\uniform on: bool;
    \\const third = 1.0 / 3.0;
    \\fn scalars(x: f32) f32 {
    \\    var s = sin(x) + cos(x) + tan(x) + asin(x) + acos(x) + atan(x) + sinh(x) + cosh(x) + tanh(x);
    \\    s += exp(x) + exp2(x) + log(x) + log2(x) + sqrt(x) + inversesqrt(x) + abs(x) + sign(x);
    \\    s += floor(x) + ceil(x) + fract(x) + round(x) + trunc(x) + pow(x, 2) + atan2(x, 1);
    \\    s += mod(x, 3) + min(x, 1) + max(x, 0) + step(0.5, x) + clamp(x, 0, 1) + mix(x, 1, 0.5) + smoothstep(0, 1, x);
    \\    s += length(x) + distance(x, 1) + dot(x, 2) + normalize(x) + reflect(x, 1);
    \\    return s * third;
    \\}
    \\fn vectors(a: vec3, b: vec3) vec3 {
    \\    var s = sin(a) + cos(a) + tan(a) + asin(a) + acos(a) + atan(a) + sinh(a) + cosh(a) + tanh(a);
    \\    s += exp(a) + exp2(a) + log(a) + log2(a) + sqrt(a) + inversesqrt(a) + abs(a) + sign(a);
    \\    s += floor(a) + ceil(a) + fract(a) + round(a) + trunc(a) + pow(a, b) + atan2(a, b);
    \\    s += mod(a, b) + mod(a, 2) + min(a, b) + min(a, 1) + max(a, 0) + step(0.5, a) + step(b, a);
    \\    s += clamp(a, 0, 1) + clamp(a, b, b + 1) + mix(a, b, 0.5) + mix(a, b, b) + smoothstep(0, 1, a) + smoothstep(b, b + 1, a);
    \\    s += vec3(length(a) + distance(a, b) + dot(a, b)) + normalize(a) + reflect(a, b) + cross(a, b);
    \\    s.xz += vec2(length(a.xy), dot(v4, v4));
    \\    s.y = s.z * 2;
    \\    return s;
    \\}
    \\fn ints(i: i32, w: u32) i32 {
    \\    var r = abs(i) + sign(i) + min(i, 3) + max(i, -3) + clamp(i, 0, 9);
    \\    r += i % 7 + i / 3 - (-i);
    \\    r <<= 1;
    \\    r >>= 1;
    \\    r ^= ~i;
    \\    r |= i & 6;
    \\    var k = abs(w) + sign(w) + min(w, 3) + max(w, 1) + clamp(w, 2, 9);
    \\    k += w % 5 + w / 3 + (w << 2) + (w >> 1) + (~w & 255);
    \\    k %= 1000;
    \\    return r + i32(k) + i32(f32(k) * 0.5) + i32(u32(i));
    \\}
    \\pub fn fragment(pos: vec2) vec4 {
    \\    var c = vec4(vectors(v3, vec3(pos, f)), scalars(pos.x));
    \\    var t = 0;
    \\    for (0..4) |k| {
    \\        if (k == 2) {
    \\            continue;
    \\        }
    \\        t += ints(n + k, u);
    \\    }
    \\    var j: u32 = 0;
    \\    while (j < 8 and !on) : (j += 1) {
    \\        if (j > u or (f > 1 and v2.x < 0)) {
    \\            break;
    \\        } else if (j == 3) {
    \\            c.w -= 0.5;
    \\        } else {
    \\            c *= 0.9;
    \\        }
    \\    }
    \\    c.rgb += backdrop(pos + v2).rgb * f32(t) + vec3(pixel(), pixel_scale()) / vec3(size(), 1);
    \\    return clamp(c, vec4(0), vec4(1));
    \\}
);
