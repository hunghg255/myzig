// d3d11.hlsl in GLSL, for the OpenGL renderer (gl.zig) and the WebGL 2
// renderer (webgl.zig): instanced quads that are rounded rectangles with
// borders (kind 0), glyph runs and icons sampled from the atlas (kind 1),
// shadows (kind 2), pictures sampled from the image atlas (kind 3), or
// boxes filled by gradients (kind 5), each clipped to its clip rectangle,
// some of whose corners may be rounded; any of them transformed (gpu.zig's
// `kind`, raster_xf.zig).
//
// gl.zig puts `#version 330 core` (OpenGL 3.3) or `#version 300 es`
// (OpenGL ES 3.0) and `#define VERTEX` or `#define FRAGMENT` first.
//
// Each pixel is what the CPU renderer (raster.zig) finds for it, by the
// same arithmetic as d3d11.hlsl: the pixels drawn are the instance's
// bounds rounded as it rounds them, distances' gradients are exact rather
// than finite differences, and textures are filtered by hand, from the
// texels. Rows are counted from the top, as raster.zig counts them: the
// vertex shader flips y, and the fragment shader counts back from the
// target's height.

precision highp float;
precision highp int;
precision highp sampler2D;

uniform vec3 frame; // the target's size in pixels, and pixels a point

#ifdef VERTEX
layout(location = 0) in vec4 a_rect;          // x, y, w, h in points
layout(location = 1) in vec4 a_color;         // straight alpha
layout(location = 2) in vec4 a_border_color;
layout(location = 3) in vec4 a_uv;            // atlas u0, v0, u1, v1
layout(location = 4) in vec4 a_clip;          // x0, y0, x1, y1
layout(location = 5) in vec4 a_params;        // radius, border width (blur for shadows), kind, clip_round
#define VARYING flat out
#else
#define VARYING flat in
#endif

VARYING vec4 v_rect;
VARYING vec4 v_color;
VARYING vec4 v_border_color;
VARYING vec4 v_uv;
VARYING vec4 v_clip;
VARYING vec4 v_params;

// The frame's rows (gpu.Frame): transforms and gradients, 1024 a row.
uniform sampler2D rows;

vec4 row_at(int r) {
    return texelFetch(rows, ivec2(r % 1024, r / 1024), 0);
}

float kind_of(float k) { return k - floor(k / 16.0) * 16.0; }

// A transformed instance's map (raster_xf.zig's Map): from the window to
// its coordinates (inv, t.xy), back (fwd, t.zw), and the clip around it.
struct Map { vec4 inv; vec4 t; vec4 fwd; vec4 outer; };

Map map_of(float k) {
    float x = floor(k / 16.0);
    if (x <= 0.0) return Map(vec4(1, 0, 0, 1), vec4(0), vec4(1, 0, 0, 1), vec4(-1e6, -1e6, 1e6, 1e6));
    int r = int(x) - 1;
    return Map(row_at(r), row_at(r + 1), row_at(r + 2), row_at(r + 3));
}

// How long a pixel is, at most, in the instance's coordinates.
float pixel_of(Map m) {
    return max(abs(m.inv.x) + abs(m.inv.z), abs(m.inv.y) + abs(m.inv.w)) / frame.z;
}

// The instance's quad in its own coordinates (raster_xf.zig's quadOf).
vec4 quad_of(vec4 rect, vec4 clip, float bw, float kind, float pix) {
    float grow = kind == 2.0 ? bw * 3.0 + pix : (kind == 0.0 || kind == 5.0) ? pix : 0.0;
    return vec4(max(rect.xy - grow, clip.xy), min(rect.xy + rect.zw + grow, clip.zw));
}

#ifdef VERTEX
// The quad is the pixels the instance covers: its rectangle (grown three
// standard deviations for a shadow's blur) within its clip, each edge
// rounded to the nearest pixel boundary, as raster.zig's `bounds`.
void main() {
    vec2 target = frame.xy;
    float scale = frame.z;
    vec2 corner = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
    float kind = kind_of(a_params.z);
    float grow = a_params.z == 2.0 ? a_params.y * 3.0 : 0.0;
    vec2 lo = max(a_rect.xy - grow, a_clip.xy);
    vec2 hi = min(a_rect.xy + a_rect.zw + grow, a_clip.zw);
    if (a_params.z >= 16.0 || kind == 5.0) {
        // The window's box around the quad, within the clip around it.
        Map m = map_of(a_params.z);
        vec4 q = quad_of(a_rect, a_clip, a_params.y, kind, pixel_of(m));
        lo = vec2(1e9);
        hi = vec2(-1e9);
        for (int k = 0; k < 4; k++) {
            vec2 l = vec2((k & 1) != 0 ? q.z : q.x, (k & 2) != 0 ? q.w : q.y);
            vec2 w = vec2(m.fwd.x * l.x + m.fwd.z * l.y + m.t.z, m.fwd.y * l.x + m.fwd.w * l.y + m.t.w);
            lo = min(lo, w);
            hi = max(hi, w);
        }
        lo = max(lo, m.outer.xy);
        hi = min(hi, m.outer.zw);
        if (q.z <= q.x || q.w <= q.y) hi = lo;
    }
    // Marks of effects and layers are drawn by passes of their own.
    if (kind == 4.0 || kind == 6.0 || kind == 7.0 || kind == 15.0) hi = lo;
    vec2 p0 = clamp(floor(lo * scale + 0.5), vec2(0.0), target);
    vec2 p1 = clamp(floor(hi * scale + 0.5), vec2(0.0), target);
    p1 = max(p1, p0);
    vec2 p = mix(p0, p1, corner);
    gl_Position = vec4(p / target * vec2(2.0, -2.0) + vec2(-1.0, 1.0), 0.0, 1.0);
    v_rect = a_rect;
    v_color = a_color;
    v_border_color = a_border_color;
    v_uv = a_uv;
    v_clip = a_clip;
    v_params = a_params;
}
#endif

#ifdef FRAGMENT
uniform sampler2D atlas;  // R8
uniform sampler2D images; // BGRA bytes, uploaded as RGBA
out vec4 out_color;

const float pi = 3.14159265358979;

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

float erf_(float x) {
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
    float dy = (end - start) / 4.0;
    float y = start + dy * 0.5;
    float alpha = 0.0;
    for (int j = 0; j < 4; j++) {
        float curved = shadow_half(py - y, hw, hh, corner);
        float lo = 0.5 + 0.5 * erf_((px - curved) * k);
        float hi = 0.5 + 0.5 * erf_((px + curved) * k);
        alpha += (hi - lo) * gaussian(y, sigma) * dy;
        y += dy;
    }
    return alpha;
}

// The signed distance to a rounded box centered at 0, and the sum of the
// absolute values of its gradient (what fwidth measures).
vec2 rounded_box(vec2 p, vec2 half_size, float r) {
    vec2 q = abs(p) - half_size + r;
    vec2 m = max(q, 0.0);
    float len = sqrt(m.x * m.x + m.y * m.y);
    float d = len + min(max(q.x, q.y), 0.0) - r;
    return vec2(d, len > 0.0 ? (m.x + m.y) / len : 1.0);
}

float coverage_of(vec2 sd, float inv) {
    float aa = max(sd.y * inv, 0.0001) * 0.5;
    return 1.0 - smoothstep(-aa, aa, sd.x);
}

// rounded_box for an instance's radius: continuous corners when negative.
vec2 shape_box(vec2 p, vec2 h, float radius, float inv) {
    if (radius < 0.0) {
        vec3 g = cont_distance(p, h, min(-radius, min(h.x, h.y)), inv / 16.0, 15u);
        return vec2(g.x, abs(g.y) + abs(g.z));
    }
    return rounded_box(p, h, min(radius, min(h.x, h.y)));
}

// How much of the pixel the clip lets through: all of it, but in its
// rounded corners.
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

// Where a texture coordinate falls between texels, as a linear filter
// with clamped edges finds it: the two texels and the second's weight.
vec3 tap(float size, float u) {
    float f = u * size - 0.5;
    float f0 = floor(f);
    return vec3(clamp(f0, 0.0, size - 1.0), clamp(f0 + 1.0, 0.0, size - 1.0), f - f0);
}

float level(ivec2 at) {
    return floor(texelFetch(atlas, at, 0).r * 255.0 + 0.5);
}

vec4 texel(ivec2 at) {
    return texelFetch(images, at, 0).bgra;
}

// The gradient's colors (gradient.zig), from row `row`.
vec3 to_srgb(vec3 c) {
    return mix(1.055 * pow(max(c, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055, c * 12.92, vec3(lessThanEqual(c, vec3(0.0031308))));
}

vec3 from_oklab(vec3 lab) {
    vec3 lms = vec3(lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z,
                    lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z,
                    lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z);
    lms = lms * lms * lms;
    return to_srgb(vec3(4.0767416621 * lms.x - 3.3077115913 * lms.y + 0.2309699292 * lms.z,
                        -1.2684380046 * lms.x + 2.6097574011 * lms.y - 0.3413193965 * lms.z,
                        -0.0041960863 * lms.x - 0.7034186147 * lms.y + 1.7076147010 * lms.z));
}

vec4 premul(vec4 c) { return vec4(c.rgb * c.a, c.a); }

// raster.zig's ditherAt: an 8x8 ordered dither's offset at the pixel, in
// levels of 1/255, added to gradients' color and shadows' alpha so they
// don't band (raster.zig's ditherColor and ditherAlpha).
float dither(vec2 pos) {
    uint x = uint(pos.x) & 7u;
    uint y = uint(pos.y) & 7u;
    uint b = 0u;
    for (uint k = 0u; k < 3u; k++) b = (b << 2) | ((((x ^ y) >> k) & 1u) << 1) | ((y >> k) & 1u);
    return ((float(b) + 0.5) / 64.0 - 0.5) * (1.0 / 255.0);
}

vec4 dithered(vec4 s, float kind, vec2 pos) {
    if (s.a <= 0.0 || (kind != 2.0 && kind != 5.0)) return s;
    float n = dither(pos);
    if (kind == 5.0) return vec4(clamp(s.rgb + n, 0.0, 1.0), s.a);
    float a = clamp(s.a + n, 0.0, 1.0);
    return vec4(s.rgb * (a / s.a), a);
}

// A picture's texel at uv: bilinear, or the nearest texel when it is drawn
// pixelated (its border width, unused by pictures, is then positive).
vec4 picture(vec2 uv, bool nearest) {
    float w = float(textureSize(images, 0).x);
    if (nearest) {
        vec2 t = clamp(floor(uv * w), 0.0, w - 1.0);
        return texel(ivec2(t));
    }
    vec3 tu = tap(w, uv.x);
    vec3 tv = tap(w, uv.y);
    return texel(ivec2(tu.x, tv.x)) * ((1.0 - tu.z) * (1.0 - tv.z))
        + texel(ivec2(tu.y, tv.x)) * (tu.z * (1.0 - tv.z))
        + texel(ivec2(tu.x, tv.y)) * ((1.0 - tu.z) * tv.z)
        + texel(ivec2(tu.y, tv.y)) * (tu.z * tv.z);
}

float gradient_place(int row, vec2 p) {
    float mode = row_at(row).x;
    vec4 geo = row_at(row + 1);
    float kind = mode - floor(mode / 4.0) * 4.0;
    if (kind < 0.5) {
        vec2 d = geo.zw - geo.xy;
        return dot(p - geo.xy, d) / max(dot(d, d), 0.0001);
    }
    vec2 d = p - geo.xy;
    if (kind < 1.5) return sqrt(d.x * d.x + d.y * d.y) / geo.z;
    float t = (atan(d.x, -d.y) - geo.z) * 0.15915494309189535;
    return t - floor(t);
}

vec4 gradient_at(int row, float t) {
    vec4 head = row_at(row);
    bool lab = head.x >= 3.5;
    int n = int(head.y);
    if (n <= 0) return vec4(0.0);
    int first = row + 2;
    vec4 a = row_at(first);
    vec4 ap = row_at(first + 1);
    if (t <= ap.x) return premul(a);
    vec4 last = row_at(first + 2 * (n - 1));
    vec4 lastp = row_at(first + 2 * (n - 1) + 1);
    if (t >= lastp.x) return premul(last);
    vec4 b = last;
    vec4 bp = lastp;
    for (int i = 1; i < n - 1; i++) {
        vec4 c = row_at(first + 2 * i);
        vec4 cp = row_at(first + 2 * i + 1);
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
    if (!lab) return vec4(a.rgb * a.a + (b.rgb * b.a - a.rgb * a.a) * f, alpha);
    if (alpha <= 0.0) return vec4(0.0);
    vec3 mixed = (ap.yzw * a.a + (bp.yzw * b.a - ap.yzw * a.a) * f) / alpha;
    return vec4(clamp(from_oklab(mixed), 0.0, 1.0) * alpha, alpha);
}

// A rounded box's distance at p (from its center) and the direction it
// grows fastest (raster_xf.zig's distance).
vec3 distance3(vec2 p, vec2 h, float r) {
    vec2 q = abs(p) - h + r;
    vec2 m = max(q, 0.0);
    float len = sqrt(m.x * m.x + m.y * m.y);
    float d = len + min(max(q.x, q.y), 0.0) - r;
    float sx = p.x < 0.0 ? -1.0 : 1.0;
    float sy = p.y < 0.0 ? -1.0 : 1.0;
    if (len > 0.0) return vec3(d, sx * m.x / len, sy * m.y / len);
    return q.x > q.y ? vec3(d, sx, 0.0) : vec3(d, 0.0, sy);
}

// How much of the pixel the distance covers, smoothed by its gradient
// through the map; and that smoothing's half width.
vec2 cover_of(Map m, vec3 d, float inv) {
    float dx = d.y * m.inv.x + d.z * m.inv.y;
    float dy = d.y * m.inv.z + d.z * m.inv.w;
    float aa = max((abs(dx) + abs(dy)) * inv, 0.0001) * 0.5;
    return vec2(1.0 - smoothstep(-aa, aa, d.x), aa);
}

// An instance transformed, or filled by a gradient (raster_xf.zig's draw).
vec4 general(vec2 world, float inv) {
    Map m = map_of(v_params.z);
    float kind = kind_of(v_params.z);
    float pix = pixel_of(m);
    vec4 q = quad_of(v_rect, v_clip, v_params.y, kind, pix);
    vec2 l = vec2(m.inv.x * world.x + m.inv.z * world.y + m.t.x, m.inv.y * world.x + m.inv.w * world.y + m.t.y);
    if (l.x < q.x || l.x > q.z || l.y < q.y || l.y > q.w) discard;
    float cut = clip_cover(v_clip, v_params.w, l, pix);
    if (cut <= 0.0) discard;
    vec4 c = v_color;
    vec2 t = (l - v_rect.xy) / v_rect.zw;
    vec2 uv = v_uv.xy + (v_uv.zw - v_uv.xy) * t;
    if (kind == 1.0) {
        float w = float(textureSize(atlas, 0).x);
        vec3 tu = tap(w, uv.x);
        vec3 tv = tap(w, uv.y);
        float t00 = level(ivec2(tu.x, tv.x));
        float t01 = level(ivec2(tu.y, tv.x));
        float t10 = level(ivec2(tu.x, tv.y));
        float t11 = level(ivec2(tu.y, tv.y));
        float top = t00 + (t01 - t00) * tu.z;
        float bottom = t10 + (t11 - t10) * tu.z;
        float a = (top + (bottom - top) * tv.z) / 255.0 * c.a;
        return vec4(c.rgb * a, a) * cut;
    }
    vec2 half_size = v_rect.zw * 0.5;
    vec2 p = l - v_rect.xy - half_size;
    float r = sign(v_params.x) * min(abs(v_params.x), min(half_size.x, half_size.y));
    if (kind == 2.0) {
        float a = shadow_alpha(p.x, p.y, half_size.x, half_size.y, r, max(v_params.y, 0.25)) * c.a;
        return vec4(c.rgb * a, a) * cut;
    }
    vec3 d = r < 0.0 ? cont_distance(p, half_size, -r, pix / 16.0, 15u) : distance3(p, half_size, r);
    vec2 cv = cover_of(m, d, inv);
    if (cv.x <= 0.0) discard;
    if (kind == 3.0) return picture(uv, v_params.y > 0.0) * (cv.x * c.a * cut);
    float bw = v_params.y;
    vec4 bc = v_border_color;
    float b = (bw > 0.0 && bc.a > 0.0) ? smoothstep(-bw - cv.y, -bw + cv.y, d.x) : 0.0;
    if (kind == 5.0) {
        int row = int(v_uv.x);
        vec4 g = gradient_at(row, gradient_place(row, l));
        vec4 pb = premul(bc);
        return (g + (pb - g) * b) * (cv.x * cut);
    }
    vec4 col = c + (bc - c) * b;
    float a = col.a * cv.x;
    return vec4(col.rgb * a, a) * cut;
}

vec4 shade() {
    float scale = frame.z;
    float inv = 1.0 / scale;
    // The pixel's center, rows from the top.
    vec2 world = (vec2(floor(gl_FragCoord.x), floor(frame.y - gl_FragCoord.y)) + 0.5) * inv;
    if (v_params.z >= 16.0 || v_params.z == 5.0) {
        return general(world, inv);
    }
    float kind = v_params.z;
    float cut = clip_cover(v_clip, v_params.w, world, inv);
    vec4 c = v_color;
    vec2 t = (world - v_rect.xy) / v_rect.zw;
    vec2 uv = v_uv.xy + (v_uv.zw - v_uv.xy) * t;

    if (kind == 1.0) {
        float w = float(textureSize(atlas, 0).x);
        vec3 tu = tap(w, uv.x);
        vec3 tv = tap(w, uv.y);
        float t00 = level(ivec2(tu.x, tv.x));
        float t01 = level(ivec2(tu.y, tv.x));
        float t10 = level(ivec2(tu.x, tv.y));
        float t11 = level(ivec2(tu.y, tv.y));
        float top = t00 + (t01 - t00) * tu.z;
        float bottom = t10 + (t11 - t10) * tu.z;
        float a = (top + (bottom - top) * tv.z) / 255.0 * c.a * cut;
        return vec4(c.rgb * a, a);
    }

    vec2 half_size = v_rect.zw * 0.5;
    vec2 center = v_rect.xy + half_size;
    float r = sign(v_params.x) * min(abs(v_params.x), min(half_size.x, half_size.y));

    if (kind == 2.0) {
        float sigma = max(v_params.y, 0.25);
        vec2 p = world - center;
        float a = shadow_alpha(p.x, p.y, half_size.x, half_size.y, r, sigma) * c.a * cut;
        return vec4(c.rgb * a, a);
    }

    if (kind == 3.0) {
        // Premultiplied already: scaled by the corners' coverage and opacity.
        vec2 sd = shape_box(world - v_rect.xy - half_size, half_size, v_params.x, inv);
        float k = coverage_of(sd, inv) * c.a * cut;
        return picture(uv, v_params.y > 0.0) * k;
    }

    vec2 sd = shape_box(world - center, half_size, v_params.x, inv);
    float aa = max(sd.y * inv, 0.0001) * 0.5;
    float coverage = 1.0 - smoothstep(-aa, aa, sd.x);
    float bw = v_params.y;
    if (bw > 0.0 && v_border_color.a > 0.0) {
        float b = smoothstep(-bw - aa, -bw + aa, sd.x);
        c = c + (v_border_color - c) * b;
    }
    float a = c.a * coverage * cut;
    return vec4(c.rgb * a, a);
}

void main() {
    vec2 px = vec2(floor(gl_FragCoord.x), floor(frame.y - gl_FragCoord.y));
    out_color = dithered(shade(), kind_of(v_params.z), px);
}
#endif
