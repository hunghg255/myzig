// The OpenGL and WebGL 2 renderers' passes for backdrop effects and
// blurred layers (gl_fx.zig, and web/host_gl.js), d3d11_fx.hlsl in GLSL:
// the CPU renderer's steps (backdrop.zig, raster_fx.zig) over textures,
// each 8 bits a channel as the CPU rounds them.
//
// The program's source starts with a version and `#define VERTEX` or the
// pass: DOWN, BLUR, LAYER, CLEAR, or EFFECT (then the effect's
// `effect_color` and its entry follow this source). Textures of passes
// hold their rows from the top, as the CPU's; the frame drawn into counts
// them from the bottom, as GL does: `fx[11].z` says which a pass draws.

precision highp float;
precision highp int;
precision highp sampler2D;

// area: the pixels drawn (x, y, w, h); info: down, sigma, radius,
// transparent past the ends; dir: the blur's direction and the source's
// texels; shape (pixels), shape2: its radius in pixels, pixels a point,
// its clip's rounding; clip (points); params[4]; origin: the backdrop's
// corner in the frame, its texels; target: size, drawn into the frame.
uniform vec4 fx[12];
#define AREA fx[0]
#define INFO fx[1]
#define DIR fx[2]
#define SHAPE fx[3]
#define SHAPE2 fx[4]
#define CLIP fx[5]
#define ORIGIN fx[10]
#define TARGET fx[11]

#ifdef VERTEX
void main() {
    vec2 corner = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
    vec2 p = AREA.xy + AREA.zw * corner;
    vec2 n = p / TARGET.xy;
    gl_Position = TARGET.z > 0.5 ? vec4(n * vec2(2.0, -2.0) + vec2(-1.0, 1.0), 0.0, 1.0) : vec4(n * 2.0 - 1.0, 0.0, 1.0);
}
#else
uniform sampler2D src;
out vec4 out_color;

// The pixel drawn, rows from the top.
ivec2 texel_at() {
    int x = int(floor(gl_FragCoord.x));
    int y = int(floor(gl_FragCoord.y));
    return TARGET.z > 0.5 ? ivec2(x, int(TARGET.y) - 1 - y) : ivec2(x, y);
}

vec4 fetch(ivec2 at) { return texelFetch(src, at, 0); }

// A value as 8 bits hold it, rounded as the CPU rounds (half up).
vec4 texel(vec4 c) { return floor(clamp(c, 0.0, 1.0) * 255.0 + 0.5) / 255.0; }

vec4 down_pass() {
    ivec2 t = texel_at();
    int k = int(INFO.x);
    ivec2 size = ivec2(DIR.zw);
    vec4 c = vec4(0.0);
    for (int dy = 0; dy < k; dy++)
        for (int dx = 0; dx < k; dx++) c += fetch(min(t * k + ivec2(dx, dy), size - 1));
    return texel(c / float(k * k));
}

vec4 blur_pass() {
    ivec2 t = texel_at();
    float sigma = INFO.y;
    int radius = int(INFO.z);
    bool clear_past = INFO.w > 0.5;
    ivec2 step = ivec2(DIR.xy);
    int n = step.x != 0 ? int(DIR.z) : int(DIR.w);
    int i = step.x != 0 ? t.x : t.y;
    float sum = 1.0;
    for (int s = 1; s <= radius; s++) sum += 2.0 * (sigma <= 0.0 ? 1.0 : exp(-float(s * s) / (2.0 * sigma * sigma)));
    vec4 c = fetch(t);
    for (int o = 1; o <= radius; o++) {
        float w = sigma <= 0.0 ? 1.0 : exp(-float(o * o) / (2.0 * sigma * sigma));
        int a = i - o;
        int b = i + o;
        if (clear_past) {
            if (a >= 0) c += fetch(t - step * o) * w;
            if (b < n) c += fetch(t + step * o) * w;
        } else {
            c += (fetch(t - step * (i - max(a, 0))) + fetch(t + step * (min(b, n - 1) - i))) * w;
        }
    }
    return texel(c / sum);
}

// What an effect's shader gets for a pixel (effect.zig).
struct EffectIn {
    vec2 p;
    vec4 rect;
    float radius;
    vec4 params[4];
};

// The blurred backdrop at p, in the frame's pixels: premultiplied RGB,
// filtered bilinearly and clamped to its edges (backdrop.zig's sample).
vec3 backdrop_at(EffectIn i, vec2 p) {
    float k = INFO.x;
    vec2 uv = (p - ORIGIN.xy) / k - 0.5;
    vec2 f = floor(uv);
    vec2 t = uv - f;
    vec2 most = ORIGIN.zw - 1.0;
    ivec2 a = ivec2(clamp(f, vec2(0.0), most));
    ivec2 b = ivec2(clamp(f + 1.0, vec2(0.0), most));
    vec3 top = fetch(ivec2(a.x, a.y)).rgb * (1.0 - t.x) + fetch(ivec2(b.x, a.y)).rgb * t.x;
    vec3 bot = fetch(ivec2(a.x, b.y)).rgb * (1.0 - t.x) + fetch(ivec2(b.x, b.y)).rgb * t.x;
    return top * (1.0 - t.y) + bot * t.y;
}

float sd_round(vec4 r, float radius, vec2 p) {
    vec2 h = r.zw * 0.5;
    float rad = min(radius, min(h.x, h.y));
    vec2 q = abs(p - r.xy - h) - h + rad;
    vec2 m = max(q, 0.0);
    return sqrt(m.x * m.x + m.y * m.y) + min(max(q.x, q.y), 0.0) - rad;
}

vec2 rounded_box(vec2 p, vec2 half_size, float r) {
    vec2 q = abs(p) - half_size + r;
    vec2 m = max(q, 0.0);
    float len = sqrt(m.x * m.x + m.y * m.y);
    float d = len + min(max(q.x, q.y), 0.0) - r;
    return vec2(d, len > 0.0 ? (m.x + m.y) / len : 1.0);
}

float clamp01(float x) { return clamp(x, 0.0, 1.0); }

// Continuous corners (raster_corner.zig), asked for by a negative radius:
// a corner's value at u inside its vertical edge and v inside its
// horizontal one, the shape's (its sides' and its corners' in `corners`),
// its gradient by differences `step` apart, and where a corner's edge is.
const float cont_extent = 1.528665;

struct Cont { float r; float e; float eff; float cx; float cy; };

Cont cont_of(float hw, float hh, float r) {
    Cont c;
    c.r = r;
    c.e = cont_extent * r;
    c.cx = clamp01((cont_extent - hw / r) / (cont_extent - 1.0));
    c.cy = clamp01((cont_extent - hh / r) / (cont_extent - 1.0));
    c.eff = c.e + (r - c.e) * max(c.cx, c.cy);
    return c;
}

float cont_dist(Cont c, float u, float v) {
    float ax = max(0.0, 1.0 - u / c.e);
    float ay = max(0.0, 1.0 - v / c.e);
    float l = sqrt(ax * ax + ay * ay);
    float hi = max(ax, ay);
    float lo = min(ax, ay);
    float rho = hi > 0.0 ? min(lo / hi, 1.0) : 0.0;
    float p = (((-0.926054 * rho + 3.15601) * rho - 3.64122) * rho + 1.26803) * rho + 0.268531;
    float f1 = l + 1.0 - 1.0 / (1.0 - rho * rho * min(l, 1.0) * p);
    float qx = max(0.0, ax * cont_extent - (cont_extent - 1.0));
    float qy = max(0.0, ay * cont_extent - (cont_extent - 1.0));
    float f2 = sqrt(qx * qx + qy * qy) * 0.654166 + 0.345834;
    float s = ay > ax ? 1.0 : -1.0;
    float w = clamp01(0.5 - s + s * rho);
    float fx = f1 + (f2 - f1) * c.cx;
    float fy = f1 + (f2 - f1) * c.cy;
    float f = fx + (fy - fx) * w;
    return min(max(c.eff - u, c.eff - v), 0.0) + c.e * (f - 1.0);
}

vec2 cont_value(Cont c, vec2 p, vec2 h, uint corners) {
    float left = p.x + h.x;
    float right = h.x - p.x;
    float top = p.y + h.y;
    float bottom = h.y - p.y;
    float d = max(max(-left, -right), max(-top, -bottom));
    float curved = 0.0;
    if ((corners & 1u) != 0u && left < c.e && top < c.e) { d = max(d, cont_dist(c, left, top)); curved = 1.0; }
    if ((corners & 2u) != 0u && right < c.e && top < c.e) { d = max(d, cont_dist(c, right, top)); curved = 1.0; }
    if ((corners & 4u) != 0u && right < c.e && bottom < c.e) { d = max(d, cont_dist(c, right, bottom)); curved = 1.0; }
    if ((corners & 8u) != 0u && left < c.e && bottom < c.e) { d = max(d, cont_dist(c, left, bottom)); curved = 1.0; }
    return vec2(d, curved);
}

vec3 cont_distance(vec2 p, vec2 h, float r, float step, uint corners) {
    Cont c = cont_of(h.x, h.y, r);
    vec2 v = cont_value(c, p, h, corners);
    if (v.y == 0.0) {
        float sx = p.x < 0.0 ? -1.0 : 1.0;
        float sy = p.y < 0.0 ? -1.0 : 1.0;
        return abs(p.x) - h.x > abs(p.y) - h.y ? vec3(v.x, sx, 0.0) : vec3(v.x, 0.0, sy);
    }
    float dx = cont_value(c, vec2(p.x + step, p.y), h, corners).x;
    float dy = cont_value(c, vec2(p.x, p.y + step), h, corners).x;
    return vec3(v.x, (dx - v.x) / step, (dy - v.x) / step);
}

float cont_inset(Cont c, float v) {
    if (v >= c.e || c.r <= 0.0) return 0.0;
    float lo = v >= c.r ? 0.0 : c.r - sqrt(v * (2.0 * c.r - v));
    float hi = c.e - sqrt(v * (2.0 * c.e - v));
    float dlo = cont_dist(c, lo, v);
    float dhi = cont_dist(c, hi, v);
    if (dlo <= 0.0) return lo;
    if (dhi >= 0.0) return hi;
    int side = 0;
    for (int k = 0; k < 5; k++) {
        float m = (lo * dhi - hi * dlo) / (dhi - dlo);
        float dm = cont_dist(c, m, v);
        if (dm > 0.0) {
            lo = m;
            dlo = dm;
            if (side == 1) dhi /= 2.0;
            side = 1;
        } else {
            hi = m;
            dhi = dm;
            if (side == -1) dlo /= 2.0;
            side = -1;
        }
    }
    return (lo * dhi - hi * dlo) / (dhi - dlo);
}

float coverage_of(vec2 sd, float inv) {
    float aa = max(sd.y * inv, 0.0001) * 0.5;
    return 1.0 - smoothstep(-aa, aa, sd.x);
}

float clip_cover(vec4 c, float clip_round, vec2 w, float inv) {
    if (clip_round <= 0.0) return 1.0;
    float m = floor(clip_round / 4096.0);
    float radius = clip_round - m * 4096.0;
    uint corners = uint(m) & 15u;
    vec2 h = (c.zw - c.xy) * 0.5;
    float r = min(radius, min(h.x, h.y));
    vec2 q = w - c.xy - h;
    if (m >= 16.0) {
        // Continuous: its curves reach farther, and only its corners cut.
        float e = r * cont_extent;
        if ((w.x > c.x + e && w.x < c.z - e) || (w.y > c.y + e && w.y < c.w - e)) return 1.0;
        vec3 g = cont_distance(q, h, r, inv / 16.0, corners);
        return coverage_of(vec2(g.x, abs(g.y) + abs(g.z)), inv);
    }
    if ((w.x > c.x + r && w.x < c.z - r) || (w.y > c.y + r && w.y < c.w - r)) return 1.0;
    uint bit = q.y < 0.0 ? (q.x < 0.0 ? 1u : 2u) : (q.x < 0.0 ? 8u : 4u);
    if ((corners & bit) == 0u) return 1.0;
    return coverage_of(rounded_box(q, h, r), inv);
}

EffectIn effect_in() {
    EffectIn i;
    i.p = vec2(texel_at()) + 0.5;
    i.rect = SHAPE;
    i.radius = SHAPE2.x;
    i.params[0] = fx[6];
    i.params[1] = fx[7];
    i.params[2] = fx[8];
    i.params[3] = fx[9];
    return i;
}

// The shape's coverage of the pixel: smoothed half a pixel each way along
// its edge, and cut by its clip's rounded corners.
float effect_cover(EffectIn i) {
    float inv = 1.0 / SHAPE2.y;
    return clamp(0.5 - sd_round(i.rect, i.radius, i.p), 0.0, 1.0) * clip_cover(CLIP, SHAPE2.z, i.p * inv, inv);
}

#ifndef EFFECT
void main() {
#if defined(DOWN)
    out_color = down_pass();
#elif defined(BLUR)
    out_color = blur_pass();
#elif defined(LAYER)
    out_color = fetch(texel_at() - ivec2(AREA.xy));
#else
    out_color = vec4(0.0);
#endif
}
#endif
#endif
