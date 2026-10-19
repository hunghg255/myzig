// myzig's one shader: instanced quads that are rounded rectangles with
// borders (kind 0), glyph runs and icons sampled from the atlas (kind 1),
// shadows (kind 2): Gaussian blurs of rounded boxes, as GPUI draws them,
// pictures sampled from the image atlas (kind 3), their corners rounded,
// or boxes filled by gradients (kind 5). Each is clipped to its clip
// rectangle, some of whose corners may be rounded (a box with rounded
// corners that clips its children); any of them may be transformed, drawn
// on the general path (`general`, raster_xf.zig's twin).
//
// Each pixel is what the CPU renderer (raster.zig) finds for it, by the
// same arithmetic as d3d11.hlsl and gl.glsl: the pixels drawn are the
// instance's bounds rounded as it rounds them, distances' gradients are
// exact rather than finite differences (fwidth), and textures are
// filtered by hand, from the texels.
#include <metal_stdlib>
using namespace metal;

struct Instance {
    float4 rect;         // x, y, w, h in points
    float4 color;        // straight alpha
    float4 border_color;
    float4 uv;           // atlas u0, v0, u1, v1
    float4 clip;         // x0, y0, x1, y1
    float radius;
    float border_width;  // blur radius for shadows
    float kind;
    float clip_round;    // corners * 4096 + radius (gpu.zig's clipRound)
};

struct VOut {
    float4 pos [[position]];
    uint inst [[flat]];
};

static float4 general_box(Instance i, constant float4 *rows, float scale);
static float kind_of(float k);
static bool is_general(float k);

// `frame`: the target's size in points, and pixels a point. The quad is
// the pixels the instance covers: its rectangle (grown three standard
// deviations for a shadow's blur) within its clip, each edge rounded to
// the nearest pixel boundary, as raster.zig's `bounds` (d3d11.hlsl's vs).
vertex VOut vs(uint vid [[vertex_id]], uint iid [[instance_id]],
               constant Instance *instances [[buffer(0)]],
               constant float4 &frame [[buffer(1)]],
               constant float4 *rows [[buffer(2)]]) {
    Instance i = instances[iid];
    float scale = frame.z;
    float2 corner = float2(vid & 1, vid >> 1);
    float kind = kind_of(i.kind);
    float grow = i.kind == 2.0 ? i.border_width * 3.0 : 0.0;
    float2 lo = max(i.rect.xy - grow, i.clip.xy);
    float2 hi = min(i.rect.xy + i.rect.zw + grow, i.clip.zw);
    if (is_general(i.kind)) {
        float4 b = general_box(i, rows, scale);
        lo = b.xy;
        hi = b.zw;
    }
    // Marks of effects and layers are drawn by passes of their own.
    if (kind == 4.0 || kind == 6.0 || kind == 7.0 || kind == 15.0) hi = lo;
    float2 target = round(frame.xy * scale);
    float2 p0 = clamp(floor(lo * scale + 0.5), 0.0, target);
    float2 p1 = max(clamp(floor(hi * scale + 0.5), 0.0, target), p0);
    float2 p = mix(p0, p1, corner);
    VOut o;
    o.pos = float4(p / target * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    o.inst = iid;
    return o;
}

// Shadows as GPUI draws them (after Evan Wallace's "fast rounded rectangle
// shadows"): the box's coverage blurred by a Gaussian, exact along x with
// erf, sampled four times along y.
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

// A shadow's half width at y from its center, narrowed by its corners:
// circular, or continuous (a negative `corner`).
static float shadow_half(float y, float hw, float hh, float corner) {
    if (corner < 0.0) return hw - cont_inset(cont_of(hw, hh, -corner), hh - abs(y));
    float delta = min(hh - corner - abs(y), 0.0);
    return hw - corner + sqrt(max(0.0, corner * corner - delta * delta));
}

static float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * M_PI_F) * sigma);
}

static float2 erf2(float2 x) {
    float2 s = sign(x), a = abs(x);
    x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    x *= x;
    return s - s / (x * x);
}

static float blur_along_x(float x, float y, float sigma, float corner, float2 half_size) {
    float curved = shadow_half(y, half_size.x, half_size.y, corner);
    float2 integral = 0.5 + 0.5 * erf2((x + float2(-curved, curved)) * (sqrt(0.5) / sigma));
    return integral.y - integral.x;
}

static float shadow_alpha(float2 p, float2 half_size, float corner, float sigma) {
    float low = p.y - half_size.y;
    float high = p.y + half_size.y;
    float start = clamp(-3.0 * sigma, low, high);
    float end = clamp(3.0 * sigma, low, high);
    float step = (end - start) / 4.0;
    float y = start + step * 0.5;
    float alpha = 0.0;
    for (int k = 0; k < 4; k++) {
        alpha += blur_along_x(p.x, p.y - y, sigma, corner, half_size) * gaussian(y, sigma) * step;
        y += step;
    }
    return alpha;
}

// The signed distance to a rounded box centered at 0, and the sum of the
// absolute values of its gradient (what fwidth measures).
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

// rounded_box for an instance's radius: continuous corners when negative.
static float2 shape_box(float2 p, float2 h, float radius, float inv) {
    if (radius < 0.0) {
        float3 g = cont_distance(p, h, min(-radius, min(h.x, h.y)), inv / 16.0, 15u);
        return float2(g.x, abs(g.y) + abs(g.z));
    }
    return rounded_box(p, h, min(radius, min(h.x, h.y)));
}

// What draws on the general path (raster_xf.zig): instances transformed
// (their kind holds their transform's first row, gpu.zig) or filled by a
// gradient (kind 5, gradient.zig), each pixel found from where its center
// is in the instance's own coordinates, as the CPU renderer finds it.
struct Map { float4 inv; float4 t; float4 fwd; float4 outer; };

static float kind_of(float k) { return k - floor(k / 16.0) * 16.0; }

static bool is_general(float k) { return k >= 16.0 || k == 5.0; }

static Map map_of(float k, constant float4 *rows) {
    Map m;
    float x = floor(k / 16.0);
    if (x <= 0.0) {
        m.inv = float4(1, 0, 0, 1);
        m.t = float4(0);
        m.fwd = float4(1, 0, 0, 1);
        m.outer = float4(-1e6, -1e6, 1e6, 1e6);
        return m;
    }
    int r = int(x) - 1;
    m.inv = rows[r];
    m.t = rows[r + 1];
    m.fwd = rows[r + 2];
    m.outer = rows[r + 3];
    return m;
}

static float pixel_of(Map m, float scale) {
    return max(abs(m.inv.x) + abs(m.inv.z), abs(m.inv.y) + abs(m.inv.w)) / scale;
}

static float4 quad_of(Instance i, float kind, float pix) {
    float grow = kind == 2.0 ? i.border_width * 3.0 + pix : (kind == 0.0 || kind == 5.0) ? pix : 0.0;
    return float4(max(i.rect.xy - grow, i.clip.xy), min(i.rect.xy + i.rect.zw + grow, i.clip.zw));
}

// The window's box around the quad within the clip around it: corners
// lo, hi in points (the vertex shader rounds them to pixels).
static float4 general_box(Instance i, constant float4 *rows, float scale) {
    float kind = kind_of(i.kind);
    Map m = map_of(i.kind, rows);
    float4 q = quad_of(i, kind, pixel_of(m, scale));
    float2 lo = float2(1e9);
    float2 hi = float2(-1e9);
    for (int k = 0; k < 4; k++) {
        float2 l = float2((k & 1) ? q.z : q.x, (k & 2) ? q.w : q.y);
        float2 w = float2(m.fwd.x * l.x + m.fwd.z * l.y + m.t.z, m.fwd.y * l.x + m.fwd.w * l.y + m.t.w);
        lo = min(lo, w);
        hi = max(hi, w);
    }
    lo = max(lo, m.outer.xy);
    hi = min(hi, m.outer.zw);
    if (q.z <= q.x || q.w <= q.y) hi = lo;
    return float4(lo, hi);
}

static float3 to_srgb(float3 c) {
    return select(1.055 * pow(max(c, 0.0), 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

static float3 from_oklab(float3 lab) {
    float3 lms = float3(lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z,
                        lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z,
                        lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z);
    lms = lms * lms * lms;
    return to_srgb(float3(4.0767416621 * lms.x - 3.3077115913 * lms.y + 0.2309699292 * lms.z,
                          -1.2684380046 * lms.x + 2.6097574011 * lms.y - 0.3413193965 * lms.z,
                          -0.0041960863 * lms.x - 0.7034186147 * lms.y + 1.7076147010 * lms.z));
}

static float4 premul(float4 c) { return float4(c.rgb * c.a, c.a); }

static float gradient_place(constant float4 *rows, int row, float2 p) {
    float mode = rows[row].x;
    float4 geo = rows[row + 1];
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

static float4 gradient_at(constant float4 *rows, int row, float t) {
    float4 head = rows[row];
    bool lab = head.x >= 3.5;
    int n = int(head.y);
    if (n <= 0) return float4(0);
    int first = row + 2;
    float4 a = rows[first];
    float4 ap = rows[first + 1];
    if (t <= ap.x) return premul(a);
    float4 last = rows[first + 2 * (n - 1)];
    float4 lastp = rows[first + 2 * (n - 1) + 1];
    if (t >= lastp.x) return premul(last);
    float4 b = last;
    float4 bp = lastp;
    for (int i = 1; i < n - 1; i++) {
        float4 c = rows[first + 2 * i];
        float4 cp = rows[first + 2 * i + 1];
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
    if (alpha <= 0.0) return float4(0);
    float3 mixed = (ap.yzw * a.a + (bp.yzw * b.a - ap.yzw * a.a) * f) / alpha;
    return float4(clamp(from_oklab(mixed), 0.0, 1.0) * alpha, alpha);
}

static float3 distance3(float2 p, float2 h, float r) {
    float2 q = abs(p) - h + r;
    float2 m = max(q, 0.0);
    float len = sqrt(m.x * m.x + m.y * m.y);
    float d = len + min(max(q.x, q.y), 0.0) - r;
    float sx = p.x < 0.0 ? -1.0 : 1.0;
    float sy = p.y < 0.0 ? -1.0 : 1.0;
    if (len > 0.0) return float3(d, sx * m.x / len, sy * m.y / len);
    return q.x > q.y ? float3(d, sx, 0.0) : float3(d, 0.0, sy);
}

static float2 cover_of(Map m, float3 d, float inv) {
    float dx = d.y * m.inv.x + d.z * m.inv.y;
    float dy = d.y * m.inv.z + d.z * m.inv.w;
    float aa = max((abs(dx) + abs(dy)) * inv, 0.0001) * 0.5;
    return float2(1.0 - smoothstep(-aa, aa, d.x), aa);
}

// How much of the pixel the clip lets through: all of it, but in its
// rounded corners (raster.zig's clipCover), smoothed by `inv`.
static float clip_cover_at(float4 c, float clip_round, float2 w, float inv) {
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

// A linear filter's tap: the two texels and the second's weight.
static float3 tap(float size, float u) {
    float f = u * size - 0.5;
    float f0 = floor(f);
    return float3(clamp(f0, 0.0, size - 1.0), clamp(f0 + 1.0, 0.0, size - 1.0), f - f0);
}

// raster.zig's ditherAt: an 8x8 ordered dither's offset at the pixel, in
// levels of 1/255, added to gradients' color and shadows' alpha so they
// don't band (raster.zig's ditherColor and ditherAlpha).
static float dither(float2 pos) {
    uint x = uint(pos.x) & 7u;
    uint y = uint(pos.y) & 7u;
    uint b = 0u;
    for (uint k = 0u; k < 3u; k++) b = (b << 2) | ((((x ^ y) >> k) & 1u) << 1) | ((y >> k) & 1u);
    return ((float(b) + 0.5) / 64.0 - 0.5) * (1.0 / 255.0);
}

static float4 dithered(float4 s, float kind, float2 pos) {
    if (s.a <= 0.0 || (kind != 2.0 && kind != 5.0)) return s;
    float n = dither(pos);
    if (kind == 5.0) return float4(saturate(s.rgb + n), s.a);
    float a = saturate(s.a + n);
    return float4(s.rgb * (a / s.a), a);
}

// A picture's texel at uv, read by hand: bilinear, or the nearest texel
// when it is drawn pixelated (its border width is then positive).
static float4 picture_at(texture2d<float> images, float2 uv, bool nearest) {
    float w = float(images.get_width());
    if (nearest) {
        float2 t = clamp(floor(uv * w), 0.0, w - 1.0);
        return images.read(uint2(t));
    }
    float3 tu = tap(w, uv.x);
    float3 tv = tap(w, uv.y);
    return images.read(uint2(tu.x, tv.x)) * ((1.0 - tu.z) * (1.0 - tv.z))
        + images.read(uint2(tu.y, tv.x)) * (tu.z * (1.0 - tv.z))
        + images.read(uint2(tu.x, tv.y)) * ((1.0 - tu.z) * tv.z)
        + images.read(uint2(tu.y, tv.y)) * (tu.z * tv.z);
}

// The atlas's coverage at uv, filtered by hand from its 8-bit texels.
static float glyph_at(texture2d<float> atlas, float2 uv) {
    float w = float(atlas.get_width());
    float3 tu = tap(w, uv.x);
    float3 tv = tap(w, uv.y);
    float t00 = round(atlas.read(uint2(tu.x, tv.x)).r * 255.0);
    float t01 = round(atlas.read(uint2(tu.y, tv.x)).r * 255.0);
    float t10 = round(atlas.read(uint2(tu.x, tv.y)).r * 255.0);
    float t11 = round(atlas.read(uint2(tu.y, tv.y)).r * 255.0);
    float top = t00 + (t01 - t00) * tu.z;
    float bottom = t10 + (t11 - t10) * tu.z;
    return (top + (bottom - top) * tv.z) / 255.0;
}

static float4 general(VOut in, Instance i, constant float4 *rows, float scale, texture2d<float> atlas, texture2d<float> images) {
    float inv = 1.0 / scale;
    float2 world = (floor(in.pos.xy) + 0.5) * inv;
    Map m = map_of(i.kind, rows);
    float kind = kind_of(i.kind);
    float pix = pixel_of(m, scale);
    float4 q = quad_of(i, kind, pix);
    float2 l = float2(m.inv.x * world.x + m.inv.z * world.y + m.t.x, m.inv.y * world.x + m.inv.w * world.y + m.t.y);
    if (l.x < q.x || l.x > q.z || l.y < q.y || l.y > q.w) discard_fragment();
    float cut = clip_cover_at(i.clip, i.clip_round, l, pix);
    if (cut <= 0.0) discard_fragment();
    float4 c = i.color;
    float2 t = (l - i.rect.xy) / i.rect.zw;
    float2 uv = i.uv.xy + (i.uv.zw - i.uv.xy) * t;
    if (kind == 1.0) {
        float a = glyph_at(atlas, uv) * c.a;
        return float4(c.rgb * a, a) * cut;
    }
    float2 half_size = i.rect.zw * 0.5;
    float2 p = l - i.rect.xy - half_size;
    float r = sign(i.radius) * min(abs(i.radius), min(half_size.x, half_size.y));
    if (kind == 2.0) {
        float a = shadow_alpha(p, half_size, r, max(i.border_width, 0.25)) * c.a;
        return float4(c.rgb * a, a) * cut;
    }
    float3 d = r < 0.0 ? cont_distance(p, half_size, -r, pix / 16.0, 15u) : distance3(p, half_size, r);
    float2 cv = cover_of(m, d, inv);
    if (cv.x <= 0.0) discard_fragment();
    if (kind == 3.0) return picture_at(images, uv, i.border_width > 0.0) * (cv.x * c.a * cut);
    float bw = i.border_width;
    float4 bc = i.border_color;
    float b = (bw > 0.0 && bc.a > 0.0) ? smoothstep(-bw - cv.y, -bw + cv.y, d.x) : 0.0;
    if (kind == 5.0) {
        int row = int(i.uv.x);
        float4 g = gradient_at(rows, row, gradient_place(rows, row, l));
        float4 pb = premul(bc);
        return (g + (pb - g) * b) * (cv.x * cut);
    }
    float4 col = c + (bc - c) * b;
    float a = col.a * cv.x;
    return float4(col.rgb * a, a) * cut;
}

// An instance as the CPU renderer draws it at the pixel's center
// (d3d11.hlsl's shade): exact distance gradients, not fwidth, and the
// textures filtered by hand.
static float4 shade(VOut in, Instance i, constant float4 *rows, float scale, texture2d<float> atlas, texture2d<float> images) {
    float inv = 1.0 / scale;
    float2 world = (floor(in.pos.xy) + 0.5) * inv;
    if (is_general(i.kind)) return general(in, i, rows, scale, atlas, images);
    float kind = i.kind;
    float cut = clip_cover_at(i.clip, i.clip_round, world, inv);
    float4 c = i.color;
    float2 t = (world - i.rect.xy) / i.rect.zw;
    float2 uv = i.uv.xy + (i.uv.zw - i.uv.xy) * t;

    if (kind == 1.0) {
        float a = glyph_at(atlas, uv) * c.a * cut;
        return float4(c.rgb * a, a);
    }

    float2 half_size = i.rect.zw * 0.5;
    float2 center = i.rect.xy + half_size;
    float r = sign(i.radius) * min(abs(i.radius), min(half_size.x, half_size.y));

    if (kind == 2.0) {
        float sigma = max(i.border_width, 0.25);
        float a = shadow_alpha(world - center, half_size, r, sigma) * c.a * cut;
        return float4(c.rgb * a, a);
    }

    if (kind == 3.0) {
        // Premultiplied already: scaled by the corners' coverage and opacity.
        float2 sd = shape_box(world - i.rect.xy - half_size, half_size, i.radius, inv);
        float k = coverage_of(sd, inv) * c.a * cut;
        return picture_at(images, uv, i.border_width > 0.0) * k;
    }

    float2 sd = shape_box(world - center, half_size, i.radius, inv);
    float aa = max(sd.y * inv, 0.0001) * 0.5;
    float coverage = 1.0 - smoothstep(-aa, aa, sd.x);
    float bw = i.border_width;
    if (bw > 0.0 && i.border_color.a > 0.0) {
        float b = smoothstep(-bw - aa, -bw + aa, sd.x);
        c = c + (i.border_color - c) * b;
    }
    float a = c.a * coverage * cut;
    return float4(c.rgb * a, a);
}

fragment float4 fs(VOut in [[stage_in]],
                   constant Instance *instances [[buffer(0)]],
                   constant float4 &frame [[buffer(1)]],
                   constant float4 *rows [[buffer(2)]],
                   texture2d<float> atlas [[texture(0)]],
                   texture2d<float> images [[texture(1)]]) {
    Instance i = instances[in.inst];
    return dithered(shade(in, i, rows, frame.z, atlas, images), kind_of(i.kind), floor(in.pos.xy));
}
