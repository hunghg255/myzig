// shader.metal in HLSL, for the Direct3D 11 renderer (d3d11.zig): instanced
// quads that are rounded rectangles with borders (kind 0), glyph runs and
// icons sampled from the atlas (kind 1), shadows (kind 2), pictures
// sampled from the image atlas (kind 3), or boxes filled by gradients
// (kind 5), each clipped to its clip rectangle, some of whose corners may
// be rounded; any of them transformed (gpu.zig's `kind`, raster_xf.zig).
//
// Each pixel is what the CPU renderer (raster.zig) finds for it, by the
// same arithmetic: the pixels drawn are the instance's bounds rounded as it
// rounds them, distances' gradients are exact rather than finite
// differences (fwidth), and textures are filtered by hand, from the
// texels, with full precision weights.

cbuffer Frame : register(b0) {
    float2 target;  // the render target's size in pixels
    float scale;    // pixels a point
    float unused;
};

Texture2D<float> atlas : register(t0);
Texture2D<float4> images : register(t1);
// The frame's rows (gpu.Frame): transforms and gradients.
Buffer<float4> rows : register(t2);

struct Instance {
    float4 rect : RECT;          // x, y, w, h in points
    float4 color : COLOR0;       // straight alpha
    float4 border_color : COLOR1;
    float4 uv : UV;              // atlas u0, v0, u1, v1
    float4 clip : CLIP;          // x0, y0, x1, y1
    float4 params : PARAMS;      // radius, border width (blur for shadows), kind, clip_round
};

struct VOut {
    float4 pos : SV_Position;
    nointerpolation float4 rect : RECT;
    nointerpolation float4 color : COLOR0;
    nointerpolation float4 border_color : COLOR1;
    nointerpolation float4 uv : UV;
    nointerpolation float4 clip : CLIP;
    nointerpolation float4 params : PARAMS;
};

// The quad is the pixels the instance covers: its rectangle (grown three
// standard deviations for a shadow's blur) within its clip, each edge
// rounded to the nearest pixel boundary, as raster.zig's `bounds`.
float kind_of(float k) { return k - floor(k / 16.0) * 16.0; }

// A transformed instance's map (raster_xf.zig's Map): from the window to
// its coordinates (inv, t.xy), back (fwd, t.zw), and the clip around it.
struct Map { float4 inv; float4 t; float4 fwd; float4 outer; };

Map map_of(float k) {
    Map m;
    float x = floor(k / 16.0);
    if (x <= 0.0) {
        m.inv = float4(1, 0, 0, 1);
        m.t = float4(0, 0, 0, 0);
        m.fwd = float4(1, 0, 0, 1);
        m.outer = float4(-1e6, -1e6, 1e6, 1e6);
        return m;
    }
    int r = int(x) - 1;
    m.inv = rows.Load(r);
    m.t = rows.Load(r + 1);
    m.fwd = rows.Load(r + 2);
    m.outer = rows.Load(r + 3);
    return m;
}

// How long a pixel is, at most, in the instance's coordinates.
float pixel_of(Map m) {
    return max(abs(m.inv.x) + abs(m.inv.z), abs(m.inv.y) + abs(m.inv.w)) / scale;
}

// The instance's quad in its own coordinates (raster_xf.zig's quadOf).
float4 quad_of(Instance i, float kind, float pix) {
    float grow = kind == 2.0 ? i.params.y * 3.0 + pix : (kind == 0.0 || kind == 5.0) ? pix : 0.0;
    return float4(max(i.rect.xy - grow, i.clip.xy), min(i.rect.xy + i.rect.zw + grow, i.clip.zw));
}

VOut vs(Instance i, uint vid : SV_VertexID) {
    float2 corner = float2(vid & 1, vid >> 1);
    float kind = kind_of(i.params.z);
    float grow = i.params.z == 2.0 ? i.params.y * 3.0 : 0.0;
    float2 lo = max(i.rect.xy - grow, i.clip.xy);
    float2 hi = min(i.rect.xy + i.rect.zw + grow, i.clip.zw);
    if (i.params.z >= 16.0 || kind == 5.0) {
        // The window's box around the quad, within the clip around it.
        Map m = map_of(i.params.z);
        float4 q = quad_of(i, kind, pixel_of(m));
        lo = float2(1e9, 1e9);
        hi = float2(-1e9, -1e9);
        [unroll] for (int k = 0; k < 4; k++) {
            float2 l = float2((k & 1) ? q.z : q.x, (k & 2) ? q.w : q.y);
            float2 w = float2(m.fwd.x * l.x + m.fwd.z * l.y + m.t.z, m.fwd.y * l.x + m.fwd.w * l.y + m.t.w);
            lo = min(lo, w);
            hi = max(hi, w);
        }
        lo = max(lo, m.outer.xy);
        hi = min(hi, m.outer.zw);
        if (q.z <= q.x || q.w <= q.y) hi = lo;
    }
    // Marks of effects and layers are drawn by passes of their own.
    if (kind == 4.0 || kind == 6.0 || kind == 7.0 || kind == 15.0) hi = lo;
    float2 p0 = clamp(floor(lo * scale + 0.5), 0.0, target);
    float2 p1 = clamp(floor(hi * scale + 0.5), 0.0, target);
    p1 = max(p1, p0);
    float2 p = lerp(p0, p1, corner);
    VOut o;
    o.pos = float4(p / target * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    o.rect = i.rect;
    o.color = i.color;
    o.border_color = i.border_color;
    o.uv = i.uv;
    o.clip = i.clip;
    o.params = i.params;
    return o;
}

static const float pi = 3.14159265358979;

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

// A shadow's half width at y from its center, narrowed by its corners:
// circular, or continuous (a negative `corner`).
float shadow_half(float y, float hw, float hh, float corner) {
    if (corner < 0.0) return hw - cont_inset(cont_of(hw, hh, -corner), hh - abs(y));
    float delta = min(hh - corner - abs(y), 0.0);
    return hw - corner + sqrt(max(0.0, corner * corner - delta * delta));
}

float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * pi) * sigma);
}

float erf(float x) {
    float s = x < 0.0 ? -1.0 : 1.0;
    float a = abs(x);
    float y = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    y *= y;
    return s - s / (y * y);
}

// The box's coverage blurred by a Gaussian, exact along x with erf,
// sampled four times along y (raster_shadow.zig).
float shadow_alpha(float px, float py, float hw, float hh, float corner, float sigma) {
    float k = sqrt(0.5) / sigma;
    float low = py - hh;
    float high = py + hh;
    float start = clamp(-3.0 * sigma, low, high);
    float end = clamp(3.0 * sigma, low, high);
    float step = (end - start) / 4.0;
    float y = start + step * 0.5;
    float alpha = 0.0;
    [unroll] for (int j = 0; j < 4; j++) {
        float curved = shadow_half(py - y, hw, hh, corner);
        float lo = 0.5 + 0.5 * erf((px - curved) * k);
        float hi = 0.5 + 0.5 * erf((px + curved) * k);
        alpha += (hi - lo) * gaussian(y, sigma) * step;
        y += step;
    }
    return alpha;
}

// The signed distance to a rounded box centered at 0, and the sum of the
// absolute values of its gradient (what fwidth measures).
float2 rounded_box(float2 p, float2 half_size, float r) {
    float2 q = abs(p) - half_size + r;
    float2 m = max(q, 0.0);
    float len = sqrt(m.x * m.x + m.y * m.y);
    float d = len + min(max(q.x, q.y), 0.0) - r;
    return float2(d, len > 0.0 ? (m.x + m.y) / len : 1.0);
}

float coverage_of(float2 sd, float inv) {
    float aa = max(sd.y * inv, 0.0001) * 0.5;
    return 1.0 - smoothstep(-aa, aa, sd.x);
}

// rounded_box for an instance's radius: continuous corners when negative.
float2 shape_box(float2 p, float2 h, float radius, float inv) {
    if (radius < 0.0) {
        float3 g = cont_distance(p, h, min(-radius, min(h.x, h.y)), inv / 16.0, 15u);
        return float2(g.x, abs(g.y) + abs(g.z));
    }
    return rounded_box(p, h, min(radius, min(h.x, h.y)));
}

// How much of the pixel the clip lets through: all of it, but in its
// rounded corners.
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

// Where a texture coordinate falls between texels, as a linear filter
// with clamped edges finds it: the two texels and the second's weight.
float3 tap(float size, float u) {
    float f = u * size - 0.5;
    float f0 = floor(f);
    return float3(clamp(f0, 0.0, size - 1.0), clamp(f0 + 1.0, 0.0, size - 1.0), f - f0);
}

// The gradient's colors (gradient.zig), from row `row`.
float3 to_linear(float3 c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }
float3 to_srgb(float3 c) { return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(max(c, 0.0), 1.0 / 2.4) - 0.055; }

float3 from_oklab(float3 lab) {
    float3 lms = float3(lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z,
                        lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z,
                        lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z);
    lms = lms * lms * lms;
    return to_srgb(float3(4.0767416621 * lms.x - 3.3077115913 * lms.y + 0.2309699292 * lms.z,
                          -1.2684380046 * lms.x + 2.6097574011 * lms.y - 0.3413193965 * lms.z,
                          -0.0041960863 * lms.x - 0.7034186147 * lms.y + 1.7076147010 * lms.z));
}

float4 premul(float4 c) { return float4(c.rgb * c.a, c.a); }

// raster.zig's ditherAt: an 8x8 ordered dither's offset at the pixel, in
// levels of 1/255, added to gradients' color and shadows' alpha so they
// don't band (`dithered`, raster.zig's ditherColor and ditherAlpha).
float dither(float2 pos) {
    uint x = uint(pos.x) & 7u;
    uint y = uint(pos.y) & 7u;
    uint b = 0u;
    [unroll] for (uint k = 0u; k < 3u; k++) b = (b << 2) | ((((x ^ y) >> k) & 1u) << 1) | ((y >> k) & 1u);
    return ((float(b) + 0.5) / 64.0 - 0.5) * (1.0 / 255.0);
}

float4 dithered(float4 s, float kind, float2 pos) {
    if (s.a <= 0.0 || (kind != 2.0 && kind != 5.0)) return s;
    float n = dither(pos);
    if (kind == 5.0) return float4(saturate(s.rgb + n), s.a);
    float a = saturate(s.a + n);
    return float4(s.rgb * (a / s.a), a);
}

// A picture's texel at uv: bilinear, or the nearest texel when it is drawn
// pixelated (its border width, unused by pictures, is then positive).
float4 picture(float2 uv, bool nearest) {
    uint w, h;
    images.GetDimensions(w, h);
    if (nearest) {
        float2 t = clamp(floor(uv * float(w)), 0.0, float(w) - 1.0);
        return images.Load(int3(int(t.x), int(t.y), 0));
    }
    float3 tu = tap(w, uv.x);
    float3 tv = tap(w, uv.y);
    return images.Load(int3(tu.x, tv.x, 0)) * ((1.0 - tu.z) * (1.0 - tv.z))
        + images.Load(int3(tu.y, tv.x, 0)) * (tu.z * (1.0 - tv.z))
        + images.Load(int3(tu.x, tv.y, 0)) * ((1.0 - tu.z) * tv.z)
        + images.Load(int3(tu.y, tv.y, 0)) * (tu.z * tv.z);
}

float gradient_place(int row, float2 p) {
    float mode = rows.Load(row).x;
    float4 geo = rows.Load(row + 1);
    float kind = mode - floor(mode / 4.0) * 4.0;
    if (kind < 0.5) {
        float2 d = geo.zw - geo.xy;
        return dot(p - geo.xy, d) / max(dot(d, d), 0.0001);
    }
    float2 d = p - geo.xy;
    if (kind < 1.5) return sqrt(d.x * d.x + d.y * d.y) / geo.z;
    float t = (atan2(d.x, -d.y) - geo.z) * 0.15915494309189535;
    return t - floor(t);
}

float4 gradient_at(int row, float t) {
    float4 head = rows.Load(row);
    bool lab = head.x >= 3.5;
    int n = int(head.y);
    if (n <= 0) return float4(0, 0, 0, 0);
    int first = row + 2;
    float4 a = rows.Load(first);
    float4 ap = rows.Load(first + 1);
    if (t <= ap.x) return premul(a);
    float4 last = rows.Load(first + 2 * (n - 1));
    float4 lastp = rows.Load(first + 2 * (n - 1) + 1);
    if (t >= lastp.x) return premul(last);
    float4 b = last;
    float4 bp = lastp;
    for (int i = 1; i < n - 1; i++) {
        float4 c = rows.Load(first + 2 * i);
        float4 cp = rows.Load(first + 2 * i + 1);
        if (t < cp.x) {
            b = c;
            bp = cp;
            break;
        }
        a = c;
        ap = cp;
    }
    float f = clamp((t - ap.x) / max(bp.x - ap.x, 1e-6), 0.0, 1.0);
    float alpha = a.a + (b.a - a.a) * f;
    if (!lab) return float4(a.rgb * a.a + (b.rgb * b.a - a.rgb * a.a) * f, alpha);
    if (alpha <= 0.0) return float4(0, 0, 0, 0);
    float3 mixed = (ap.yzw * a.a + (bp.yzw * b.a - ap.yzw * a.a) * f) / alpha;
    return float4(clamp(from_oklab(mixed), 0.0, 1.0) * alpha, alpha);
}

// A rounded box's distance at p (from its center) and the direction it
// grows fastest (raster_xf.zig's distance).
float3 distance3(float2 p, float2 h, float r) {
    float2 q = abs(p) - h + r;
    float2 m = max(q, 0.0);
    float len = sqrt(m.x * m.x + m.y * m.y);
    float d = len + min(max(q.x, q.y), 0.0) - r;
    float sx = p.x < 0.0 ? -1.0 : 1.0;
    float sy = p.y < 0.0 ? -1.0 : 1.0;
    if (len > 0.0) return float3(d, sx * m.x / len, sy * m.y / len);
    return q.x > q.y ? float3(d, sx, 0.0) : float3(d, 0.0, sy);
}

// How much of the pixel the distance covers, smoothed by its gradient
// through the map; and that smoothing's half width.
float2 cover_of(Map m, float3 d, float inv) {
    float dx = d.y * m.inv.x + d.z * m.inv.y;
    float dy = d.y * m.inv.z + d.z * m.inv.w;
    float aa = max((abs(dx) + abs(dy)) * inv, 0.0001) * 0.5;
    return float2(1.0 - smoothstep(-aa, aa, d.x), aa);
}

// An instance transformed, or filled by a gradient (raster_xf.zig's draw).
float4 general(VOut v, float2 world, float inv) {
    Instance i;
    i.rect = v.rect;
    i.color = v.color;
    i.border_color = v.border_color;
    i.uv = v.uv;
    i.clip = v.clip;
    i.params = v.params;
    Map m = map_of(v.params.z);
    float kind = kind_of(v.params.z);
    float pix = pixel_of(m);
    float4 q = quad_of(i, kind, pix);
    float2 l = float2(m.inv.x * world.x + m.inv.z * world.y + m.t.x, m.inv.y * world.x + m.inv.w * world.y + m.t.y);
    if (l.x < q.x || l.x > q.z || l.y < q.y || l.y > q.w) discard;
    float cut = clip_cover(v.clip, v.params.w, l, pix);
    if (cut <= 0.0) discard;
    float4 c = v.color;
    float2 t = (l - v.rect.xy) / v.rect.zw;
    float2 uv = v.uv.xy + (v.uv.zw - v.uv.xy) * t;
    if (kind == 1.0) {
        uint w, h;
        atlas.GetDimensions(w, h);
        float3 tu = tap(w, uv.x);
        float3 tv = tap(w, uv.y);
        float t00 = round(atlas.Load(int3(tu.x, tv.x, 0)) * 255.0);
        float t01 = round(atlas.Load(int3(tu.y, tv.x, 0)) * 255.0);
        float t10 = round(atlas.Load(int3(tu.x, tv.y, 0)) * 255.0);
        float t11 = round(atlas.Load(int3(tu.y, tv.y, 0)) * 255.0);
        float top = t00 + (t01 - t00) * tu.z;
        float bottom = t10 + (t11 - t10) * tu.z;
        float a = (top + (bottom - top) * tv.z) / 255.0 * c.a;
        return float4(c.rgb * a, a) * cut;
    }
    float2 half_size = v.rect.zw * 0.5;
    float2 p = l - v.rect.xy - half_size;
    float r = sign(v.params.x) * min(abs(v.params.x), min(half_size.x, half_size.y));
    if (kind == 2.0) {
        float a = shadow_alpha(p.x, p.y, half_size.x, half_size.y, r, max(v.params.y, 0.25)) * c.a;
        return float4(c.rgb * a, a) * cut;
    }
    float3 d = r < 0.0 ? cont_distance(p, half_size, -r, pix / 16.0, 15u) : distance3(p, half_size, r);
    float2 cv = cover_of(m, d, inv);
    if (cv.x <= 0.0) discard;
    if (kind == 3.0) return picture(uv, v.params.y > 0.0) * (cv.x * c.a * cut);
    float bw = v.params.y;
    float4 bc = v.border_color;
    float b = (bw > 0.0 && bc.a > 0.0) ? smoothstep(-bw - cv.y, -bw + cv.y, d.x) : 0.0;
    if (kind == 5.0) {
        int row = int(v.uv.x);
        float4 g = gradient_at(row, gradient_place(row, l));
        float4 pb = premul(bc);
        return (g + (pb - g) * b) * (cv.x * cut);
    }
    float4 col = c + (bc - c) * b;
    float a = col.a * cv.x;
    return float4(col.rgb * a, a) * cut;
}

float4 shade(VOut v) {
    float inv = 1.0 / scale;
    float2 world = (floor(v.pos.xy) + 0.5) * inv;
    if (v.params.z >= 16.0 || v.params.z == 5.0) return general(v, world, inv);
    float kind = v.params.z;
    float cut = clip_cover(v.clip, v.params.w, world, inv);
    float4 c = v.color;
    float2 t = (world - v.rect.xy) / v.rect.zw;
    float2 uv = v.uv.xy + (v.uv.zw - v.uv.xy) * t;

    if (kind == 1.0) {
        uint w, h;
        atlas.GetDimensions(w, h);
        float3 tu = tap(w, uv.x);
        float3 tv = tap(w, uv.y);
        float t00 = round(atlas.Load(int3(tu.x, tv.x, 0)) * 255.0);
        float t01 = round(atlas.Load(int3(tu.y, tv.x, 0)) * 255.0);
        float t10 = round(atlas.Load(int3(tu.x, tv.y, 0)) * 255.0);
        float t11 = round(atlas.Load(int3(tu.y, tv.y, 0)) * 255.0);
        float top = t00 + (t01 - t00) * tu.z;
        float bottom = t10 + (t11 - t10) * tu.z;
        float a = (top + (bottom - top) * tv.z) / 255.0 * c.a * cut;
        return float4(c.rgb * a, a);
    }

    float2 half_size = v.rect.zw * 0.5;
    float2 center = v.rect.xy + half_size;
    float r = sign(v.params.x) * min(abs(v.params.x), min(half_size.x, half_size.y));

    if (kind == 2.0) {
        float sigma = max(v.params.y, 0.25);
        float2 p = world - center;
        float a = shadow_alpha(p.x, p.y, half_size.x, half_size.y, r, sigma) * c.a * cut;
        return float4(c.rgb * a, a);
    }

    if (kind == 3.0) {
        // Premultiplied already: scaled by the corners' coverage and opacity.
        float2 sd = shape_box(world - v.rect.xy - half_size, half_size, v.params.x, inv);
        float k = coverage_of(sd, inv) * c.a * cut;
        return picture(uv, v.params.y > 0.0) * k;
    }

    float2 sd = shape_box(world - center, half_size, v.params.x, inv);
    float aa = max(sd.y * inv, 0.0001) * 0.5;
    float coverage = 1.0 - smoothstep(-aa, aa, sd.x);
    float bw = v.params.y;
    if (bw > 0.0 && v.border_color.a > 0.0) {
        float b = smoothstep(-bw - aa, -bw + aa, sd.x);
        c = c + (v.border_color - c) * b;
    }
    float a = c.a * coverage * cut;
    return float4(c.rgb * a, a);
}

float4 ps(VOut v) : SV_Target {
    return dithered(shade(v), kind_of(v.params.z), floor(v.pos.xy));
}
