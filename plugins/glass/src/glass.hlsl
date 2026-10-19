// The glass in HLSL, for myzig's Direct3D renderer: its effect's color
// (src/ui/effect.zig), after mygo's glass.hlsl, as material.zig and
// pixels.zig find it on the CPU. The parameters (shader.zig): params[0]
// the bezel, the refraction, the rim and its width; params[1] the tint;
// params[2] the low, high, curve and saturation; params[3] the light.

float glass_lens(float t, float bezel) {
    if (bezel <= 0 || t >= bezel) return 0;
    float u = 1 - max(t, 0) / bezel;
    float v = 1 - u * u * u * u;
    float a = sqrt(v * sqrt(v));
    float b = u * u * u;
    float n = sqrt(a * a + b * b);
    float s = b / n;
    float c = a / n;
    float st = s / 1.5;
    float ct = sqrt(1 - st * st);
    return (s * ct - c * st) / (c * ct + s * st) / 1.1180340;
}

float2 glass_normal(float2 p, float4 rect, float radius) {
    float2 h = rect.zw * 0.5;
    float2 q = p - rect.xy - h;
    float r = min(radius * 1.5, min(h.x, h.y));
    float2 a = abs(q) - (h - r);
    float2 sq = float2(sign(q));
    if (a.x > 0 || a.y > 0) {
        float2 m = max(a, 0);
        return sq * m / sqrt(m.x * m.x + m.y * m.y);
    }
    return a.x > a.y ? float2(sq.x, 0) : float2(0, sq.y);
}

float3 glass_tone(float3 c, float4 tone) {
    float l = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    float t = tone.x + (tone.y - tone.x) * (1 - pow(max(1 - l, 0), tone.z));
    float k = (tone.y - tone.x) * tone.w;
    return saturate(t + (c - l) * k);
}

float3 effect_color(EffectIn i) {
    float t = max(-sd_round(i.rect, i.radius, i.p), 0);
    float bezel = i.params[0].x;
    float rim_width = i.params[0].w;
    float2 n = float2(0, 0);
    if (t < bezel || t < 3 * rim_width) n = glass_normal(i.p, i.rect, i.radius);
    float2 q = i.p;
    if (t < bezel) q -= n * (i.params[0].y * glass_lens(t, bezel));
    float3 c = glass_tone(backdrop_at(i, q), i.params[2]);
    c += (i.params[1].rgb - c) * i.params[1].a;
    if (i.params[0].z > 0 && t < 3 * rim_width) {
        float r = t / rim_width;
        float a = i.params[0].z * exp(-r * r);
        float l = abs(n.x * i.params[3].x + n.y * i.params[3].y);
        c += (l - c) * a;
    }
    return c;
}
