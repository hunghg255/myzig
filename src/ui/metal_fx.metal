// The Metal renderer's passes for backdrop effects and blurred layers
// (metal_fx.zig), d3d11_fx.hlsl in Metal: the CPU renderer's steps
// (backdrop.zig, raster_fx.zig) over textures, each 8 bits a channel as
// the CPU rounds them. An effect's `effect_color` and its entry point
// follow this source.
#include <metal_stdlib>
using namespace metal;

// area: the pixels drawn (x, y, w, h); info: down, sigma, radius,
// transparent past the ends; dir: the blur's direction and the source's
// texels; shape (pixels), shape2: its radius in pixels, pixels a point,
// its clip's rounding; clip (points); params; origin: the backdrop's
// corner in the frame, its texels; target: the size drawn into.
struct Fx {
    float4 area;
    float4 info;
    float4 dir;
    float4 shape;
    float4 shape2;
    float4 clip;
    float4 params[4];
    float4 origin;
    float4 target;
};

struct FxOut {
    float4 pos [[position]];
};

vertex FxOut fx_vs(uint vid [[vertex_id]], constant Fx &fx [[buffer(0)]]) {
    float2 corner = float2(vid & 1, vid >> 1);
    float2 p = fx.area.xy + fx.area.zw * corner;
    FxOut o;
    o.pos = float4(p / fx.target.xy * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return o;
}

static int2 texel_at(FxOut v) { return int2(floor(v.pos.xy)); }

static float4 texel(float4 c) { return floor(saturate(c) * 255.0 + 0.5) / 255.0; }

static float4 fetch(texture2d<float> src, int2 at) { return src.read(uint2(at)); }

fragment float4 fx_down(FxOut v [[stage_in]], constant Fx &fx [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
    int2 t = texel_at(v);
    int k = int(fx.info.x);
    int2 size = int2(fx.dir.zw);
    float4 c = float4(0);
    for (int dy = 0; dy < k; dy++)
        for (int dx = 0; dx < k; dx++) c += fetch(src, min(t * k + int2(dx, dy), size - 1));
    return texel(c / float(k * k));
}

fragment float4 fx_blur(FxOut v [[stage_in]], constant Fx &fx [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
    int2 t = texel_at(v);
    float sigma = fx.info.y;
    int radius = int(fx.info.z);
    bool clear_past = fx.info.w > 0.5;
    int2 step = int2(fx.dir.xy);
    int n = step.x != 0 ? int(fx.dir.z) : int(fx.dir.w);
    int i = step.x != 0 ? t.x : t.y;
    float sum = 1.0;
    for (int s = 1; s <= radius; s++) sum += 2.0 * (sigma <= 0.0 ? 1.0 : exp(-float(s * s) / (2.0 * sigma * sigma)));
    float4 c = fetch(src, t);
    for (int o = 1; o <= radius; o++) {
        float w = sigma <= 0.0 ? 1.0 : exp(-float(o * o) / (2.0 * sigma * sigma));
        int a = i - o;
        int b = i + o;
        if (clear_past) {
            if (a >= 0) c += fetch(src, t - step * o) * w;
            if (b < n) c += fetch(src, t + step * o) * w;
        } else {
            c += (fetch(src, t - step * (i - max(a, 0))) + fetch(src, t + step * (min(b, n - 1) - i))) * w;
        }
    }
    return texel(c / sum);
}

fragment float4 fx_layer(FxOut v [[stage_in]], constant Fx &fx [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
    return fetch(src, texel_at(v) - int2(fx.area.xy));
}

fragment float4 fx_clear(FxOut v [[stage_in]]) {
    return float4(0);
}

// What an effect's shader gets for a pixel (effect.zig), and the
// backdrop's place in the frame.
struct EffectIn {
    float2 p;
    float4 rect;
    float radius;
    float4 params[4];
    float down;
    float4 origin;
};

// The blurred backdrop at p, in the frame's pixels: premultiplied RGB,
// filtered bilinearly and clamped to its edges (backdrop.zig's sample).
static float3 backdrop_at(EffectIn i, texture2d<float> backdrop, float2 p) {
    float2 uv = (p - i.origin.xy) / i.down - 0.5;
    float2 f = floor(uv);
    float2 t = uv - f;
    float2 most = i.origin.zw - 1.0;
    int2 a = int2(clamp(f, float2(0), most));
    int2 b = int2(clamp(f + 1.0, float2(0), most));
    float3 top = fetch(backdrop, int2(a.x, a.y)).rgb * (1.0 - t.x) + fetch(backdrop, int2(b.x, a.y)).rgb * t.x;
    float3 bot = fetch(backdrop, int2(a.x, b.y)).rgb * (1.0 - t.x) + fetch(backdrop, int2(b.x, b.y)).rgb * t.x;
    return top * (1.0 - t.y) + bot * t.y;
}

static float sd_round(float4 r, float radius, float2 p) {
    float2 h = r.zw * 0.5;
    float rad = min(radius, min(h.x, h.y));
    float2 q = abs(p - r.xy - h) - h + rad;
    float2 m = max(q, 0.0);
    return sqrt(m.x * m.x + m.y * m.y) + min(max(q.x, q.y), 0.0) - rad;
}

// Continuous corners (raster_corner.zig), asked for by a negative radius:
// a corner's value at u inside its vertical edge and v inside its
// horizontal one, the shape's (its sides' and its corners' in `corners`),
// its gradient by differences `step` apart, and where a corner's edge is.
constant float cont_extent = 1.528665;

struct Cont { float r; float e; float eff; float cx; float cy; };

static Cont cont_of(float hw, float hh, float r) {
    Cont c;
    c.r = r;
    c.e = cont_extent * r;
    c.cx = saturate((cont_extent - hw / r) / (cont_extent - 1.0));
    c.cy = saturate((cont_extent - hh / r) / (cont_extent - 1.0));
    c.eff = c.e + (r - c.e) * max(c.cx, c.cy);
    return c;
}

static float cont_dist(Cont c, float u, float v) {
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
    float w = saturate(0.5 - s + s * rho);
    float fx = f1 + (f2 - f1) * c.cx;
    float fy = f1 + (f2 - f1) * c.cy;
    float f = fx + (fy - fx) * w;
    return min(max(c.eff - u, c.eff - v), 0.0) + c.e * (f - 1.0);
}

static float2 cont_value(Cont c, float2 p, float2 h, uint corners) {
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
    return float2(d, curved);
}

static float3 cont_distance(float2 p, float2 h, float r, float step, uint corners) {
    Cont c = cont_of(h.x, h.y, r);
    float2 v = cont_value(c, p, h, corners);
    if (v.y == 0.0) {
        float sx = p.x < 0.0 ? -1.0 : 1.0;
        float sy = p.y < 0.0 ? -1.0 : 1.0;
        return abs(p.x) - h.x > abs(p.y) - h.y ? float3(v.x, sx, 0.0) : float3(v.x, 0.0, sy);
    }
    float dx = cont_value(c, float2(p.x + step, p.y), h, corners).x;
    float dy = cont_value(c, float2(p.x, p.y + step), h, corners).x;
    return float3(v.x, (dx - v.x) / step, (dy - v.x) / step);
}

static float cont_inset(Cont c, float v) {
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

static float2 rounded_box(float2 p, float2 half_size, float r) {
    float2 q = abs(p) - half_size + r;
    float2 m = max(q, 0.0);
    float len = sqrt(m.x * m.x + m.y * m.y);
    float d = len + min(max(q.x, q.y), 0.0) - r;
    return float2(d, len > 0.0 ? (m.x + m.y) / len : 1.0);
}

static float coverage_of(float2 sd, float inv) {
    float aa = max(sd.y * inv, 0.0001) * 0.5;
    return 1.0 - smoothstep(-aa, aa, sd.x);
}

static float fx_clip_cover(float4 c, float clip_round, float2 w, float inv) {
    if (clip_round <= 0.0) return 1.0;
    float m = floor(clip_round / 4096.0);
    float radius = clip_round - m * 4096.0;
    uint corners = uint(m) & 15u;
    float2 h = (c.zw - c.xy) * 0.5;
    float r = min(radius, min(h.x, h.y));
    float2 q = w - c.xy - h;
    if (m >= 16.0) {
        // Continuous: its curves reach farther, and only its corners cut.
        float e = r * cont_extent;
        if ((w.x > c.x + e && w.x < c.z - e) || (w.y > c.y + e && w.y < c.w - e)) return 1.0;
        float3 g = cont_distance(q, h, r, inv / 16.0, corners);
        return coverage_of(float2(g.x, abs(g.y) + abs(g.z)), inv);
    }
    if ((w.x > c.x + r && w.x < c.z - r) || (w.y > c.y + r && w.y < c.w - r)) return 1.0;
    uint bit = q.y < 0.0 ? (q.x < 0.0 ? 1u : 2u) : (q.x < 0.0 ? 8u : 4u);
    if ((corners & bit) == 0u) return 1.0;
    return coverage_of(rounded_box(q, h, r), inv);
}

static EffectIn effect_in(FxOut v, constant Fx &fx) {
    EffectIn i;
    i.p = floor(v.pos.xy) + 0.5;
    i.rect = fx.shape;
    i.radius = fx.shape2.x;
    for (int k = 0; k < 4; k++) i.params[k] = fx.params[k];
    i.down = fx.info.x;
    i.origin = fx.origin;
    return i;
}

static float effect_cover(EffectIn i, constant Fx &fx) {
    float inv = 1.0 / fx.shape2.y;
    return saturate(0.5 - sd_round(i.rect, i.radius, i.p)) * fx_clip_cover(fx.clip, fx.shape2.z, i.p * inv, inv);
}
