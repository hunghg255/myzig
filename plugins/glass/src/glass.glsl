// The glass in GLSL, for myzig's OpenGL and WebGL renderers: its effect's
// color (src/ui/effect.zig), as glass.hlsl is in HLSL.

float glass_lens(float t, float bezel) {
    if (bezel <= 0.0 || t >= bezel) return 0.0;
    float u = 1.0 - max(t, 0.0) / bezel;
    float v = 1.0 - u * u * u * u;
    float a = sqrt(v * sqrt(v));
    float b = u * u * u;
    float n = sqrt(a * a + b * b);
    float s = b / n;
    float c = a / n;
    float st = s / 1.5;
    float ct = sqrt(1.0 - st * st);
    return (s * ct - c * st) / (c * ct + s * st) / 1.1180340;
}

vec2 glass_normal(vec2 p, vec4 rect, float radius) {
    vec2 h = rect.zw * 0.5;
    vec2 q = p - rect.xy - h;
    float r = min(radius * 1.5, min(h.x, h.y));
    vec2 a = abs(q) - (h - r);
    vec2 sq = sign(q);
    if (a.x > 0.0 || a.y > 0.0) {
        vec2 m = max(a, vec2(0.0));
        return sq * m / sqrt(m.x * m.x + m.y * m.y);
    }
    return a.x > a.y ? vec2(sq.x, 0.0) : vec2(0.0, sq.y);
}

vec3 glass_tone(vec3 c, vec4 tone) {
    float l = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    float t = tone.x + (tone.y - tone.x) * (1.0 - pow(max(1.0 - l, 0.0), tone.z));
    float k = (tone.y - tone.x) * tone.w;
    return clamp(t + (c - l) * k, 0.0, 1.0);
}

vec3 effect_color(EffectIn i) {
    float t = max(-sd_round(i.rect, i.radius, i.p), 0.0);
    float bezel = i.params[0].x;
    float rim_width = i.params[0].w;
    vec2 n = vec2(0.0);
    if (t < bezel || t < 3.0 * rim_width) n = glass_normal(i.p, i.rect, i.radius);
    vec2 q = i.p;
    if (t < bezel) q -= n * (i.params[0].y * glass_lens(t, bezel));
    vec3 c = glass_tone(backdrop_at(i, q), i.params[2]);
    c += (i.params[1].rgb - c) * i.params[1].a;
    if (i.params[0].z > 0.0 && t < 3.0 * rim_width) {
        float r = t / rim_width;
        float a = i.params[0].z * exp(-r * r);
        float l = abs(n.x * i.params[3].x + n.y * i.params[3].y);
        c += (l - c) * a;
    }
    return c;
}
