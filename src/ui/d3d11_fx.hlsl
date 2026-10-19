// The Direct3D renderer's passes for backdrop effects and blurred layers
// (d3d11_fx.zig), the CPU renderer's steps (backdrop.zig, raster_fx.zig)
// over textures, each 8 bits a channel as the CPU rounds them:
//
// - `down`: the area copied, averaged over squares of `down` texels;
// - `blur`: a Gaussian along rows or columns, clamped at the ends (a
//   backdrop) or transparent past them (a layer);
// - `effect`: the shape drawn from the blurred backdrop by the effect's
//   `effect_color`, appended after this source with its entry point;
// - `layer`: a blurred layer drawn over what was under it; `clear`: its
//   area made transparent.

cbuffer Fx : register(b0) {
    float4 area;      // the pixels drawn: x, y, w, h in the target
    float4 info;      // down, sigma, radius, transparent past the ends
    float4 dir;       // the blur's direction, and the source's texels
    float4 shape;     // the effect's shape in pixels
    float4 shape2;    // its radius in pixels, pixels a point, its clip's rounding
    float4 clip;      // its clip, in points
    float4 params[4]; // the effect's parameters
    float4 origin;    // the backdrop's corner in the target, its texels across and down
    float4 target;    // the target's size in pixels
};

Texture2D<float4> src : register(t0);

struct VOut {
    float4 pos : SV_Position;
};

// The area's quad, in the target's pixels.
VOut vs(uint vid : SV_VertexID) {
    float2 corner = float2(vid & 1, vid >> 1);
    float2 p = area.xy + area.zw * corner;
    VOut o;
    o.pos = float4(p / target.xy * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return o;
}

int2 texel_at(VOut v) { return int2(floor(v.pos.xy)); }

// A value as 8 bits hold it, rounded as the CPU rounds (half up).
float4 texel(float4 c) { return floor(saturate(c) * 255.0 + 0.5) / 255.0; }

float4 down(VOut v) : SV_Target {
    int2 t = texel_at(v);
    int k = int(info.x);
    int2 size = int2(dir.zw);
    float4 c = float4(0, 0, 0, 0);
    for (int dy = 0; dy < k; dy++) {
        for (int dx = 0; dx < k; dx++) {
            int2 at = min(t * k + int2(dx, dy), size - 1);
            c += src.Load(int3(at, 0));
        }
    }
    return texel(c / float(k * k));
}

float4 blur(VOut v) : SV_Target {
    int2 t = texel_at(v);
    float sigma = info.y;
    int radius = int(info.z);
    bool clear_past = info.w > 0.5;
    int2 step = int2(dir.xy);
    int n = step.x != 0 ? int(dir.z) : int(dir.w);
    int i = step.x != 0 ? t.x : t.y;
    float sum = 1.0;
    for (int s = 1; s <= radius; s++) sum += 2.0 * (sigma <= 0.0 ? 1.0 : exp(-(s * s) / (2.0 * sigma * sigma)));
    float4 c = src.Load(int3(t, 0));
    for (int o = 1; o <= radius; o++) {
        float w = sigma <= 0.0 ? 1.0 : exp(-(o * o) / (2.0 * sigma * sigma));
        int a = i - o;
        int b = i + o;
        if (clear_past) {
            if (a >= 0) c += src.Load(int3(t - step * o, 0)) * w;
            if (b < n) c += src.Load(int3(t + step * o, 0)) * w;
        } else {
            int2 ta = t - step * (i - max(a, 0));
            int2 tb = t + step * (min(b, n - 1) - i);
            c += (src.Load(int3(ta, 0)) + src.Load(int3(tb, 0))) * w;
        }
    }
    return texel(c / sum);
}

float4 layer(VOut v) : SV_Target {
    return src.Load(int3(texel_at(v) - int2(area.xy), 0));
}

float4 clear(VOut v) : SV_Target {
    return float4(0, 0, 0, 0);
}

// What an effect's shader gets for a pixel (effect.zig).
struct EffectIn {
    float2 p;
    float4 rect;
    float radius;
    float4 params[4];
};

// The blurred backdrop at p, in the target's pixels: premultiplied RGB,
// filtered bilinearly and clamped to its edges (backdrop.zig's sample).
float3 backdrop_at(EffectIn i, float2 p) {
    float k = info.x;
    float2 uv = (p - origin.xy) / k - 0.5;
    float2 f = floor(uv);
    float2 t = uv - f;
    int2 size = int2(origin.zw);
    int2 a = int2(clamp(f, 0.0, float2(size - 1)));
    int2 b = int2(clamp(f + 1.0, 0.0, float2(size - 1)));
    float3 c00 = src.Load(int3(a.x, a.y, 0)).rgb;
    float3 c10 = src.Load(int3(b.x, a.y, 0)).rgb;
    float3 c01 = src.Load(int3(a.x, b.y, 0)).rgb;
    float3 c11 = src.Load(int3(b.x, b.y, 0)).rgb;
    float3 top = c00 * (1.0 - t.x) + c10 * t.x;
    float3 bot = c01 * (1.0 - t.x) + c11 * t.x;
    return top * (1.0 - t.y) + bot * t.y;
}

float sd_round(float4 r, float radius, float2 p) {
    float2 h = r.zw * 0.5;
    float rad = min(radius, min(h.x, h.y));
    float2 q = abs(p - r.xy - h) - h + rad;
    float2 m = max(q, 0.0);
    return sqrt(m.x * m.x + m.y * m.y) + min(max(q.x, q.y), 0.0) - rad;
}

float2 rounded_box(float2 p, float2 half_size, float r) {
    float2 q = abs(p) - half_size + r;
    float2 m = max(q, 0.0);
    float len = sqrt(m.x * m.x + m.y * m.y);
    float d = len + min(max(q.x, q.y), 0.0) - r;
    return float2(d, len > 0.0 ? (m.x + m.y) / len : 1.0);
}

// How much of the pixel the clip lets through (d3d11.hlsl's clip_cover).
// Continuous corners (raster_corner.zig), asked for by a negative radius:
// a corner's value at u inside its vertical edge and v inside its
// horizontal one, the shape's (its sides' and its corners' in `corners`),
// its gradient by differences `step` apart, and where a corner's edge is.
static const float cont_extent = 1.528665;

struct Cont { float r; float e; float eff; float cx; float cy; };

Cont cont_of(float hw, float hh, float r) {
    Cont c;
    c.r = r;
    c.e = cont_extent * r;
    c.cx = saturate((cont_extent - hw / r) / (cont_extent - 1.0));
    c.cy = saturate((cont_extent - hh / r) / (cont_extent - 1.0));
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
    float w = saturate(0.5 - s + s * rho);
    float fx = f1 + (f2 - f1) * c.cx;
    float fy = f1 + (f2 - f1) * c.cy;
    float f = fx + (fy - fx) * w;
    return min(max(c.eff - u, c.eff - v), 0.0) + c.e * (f - 1.0);
}

float2 cont_value(Cont c, float2 p, float2 h, uint corners) {
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

float3 cont_distance(float2 p, float2 h, float r, float step, uint corners) {
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

float coverage_of(float2 sd, float inv) {
    float aa = max(sd.y * inv, 0.0001) * 0.5;
    return 1.0 - smoothstep(-aa, aa, sd.x);
}

float clip_cover(float4 c, float clip_round, float2 w, float inv) {
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

EffectIn effect_in(VOut v) {
    EffectIn i;
    i.p = floor(v.pos.xy) + 0.5;
    i.rect = shape;
    i.radius = shape2.x;
    i.params = params;
    return i;
}

// The shape's coverage of the pixel: smoothed half a pixel each way along
// its edge, and cut by its clip's rounded corners.
float effect_cover(EffectIn i) {
    float inv = 1.0 / shape2.y;
    return saturate(0.5 - sd_round(i.rect, i.radius, i.p)) * clip_cover(clip, shape2.z, i.p * inv, inv);
}
