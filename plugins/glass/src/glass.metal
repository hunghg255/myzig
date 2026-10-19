// The glass in Metal, for myzig's Metal renderer: its effect's color
// (src/ui/effect.zig), as glass.hlsl is in HLSL.

static float glass_lens(float t, float bezel) {
    if (bezel <= 0.0f || t >= bezel) return 0.0f;
    float u = 1.0f - max(t, 0.0f) / bezel;
    float v = 1.0f - u * u * u * u;
    float a = sqrt(v * sqrt(v));
    float b = u * u * u;
    float n = sqrt(a * a + b * b);
    float s = b / n;
    float c = a / n;
    float st = s / 1.5f;
    float ct = sqrt(1.0f - st * st);
    return (s * ct - c * st) / (c * ct + s * st) / 1.1180340f;
}

static float2 glass_normal(float2 p, float4 rect, float radius) {
    float2 h = rect.zw * 0.5f;
    float2 q = p - rect.xy - h;
    float r = min(radius * 1.5f, min(h.x, h.y));
    float2 a = abs(q) - (h - r);
    float2 sq = sign(q);
    if (a.x > 0.0f || a.y > 0.0f) {
        float2 m = max(a, float2(0.0f));
        return sq * m / sqrt(m.x * m.x + m.y * m.y);
    }
    return a.x > a.y ? float2(sq.x, 0.0f) : float2(0.0f, sq.y);
}

static float3 glass_tone(float3 c, float4 tone) {
    float l = 0.2126f * c.r + 0.7152f * c.g + 0.0722f * c.b;
    float t = tone.x + (tone.y - tone.x) * (1.0f - pow(max(1.0f - l, 0.0f), tone.z));
    float k = (tone.y - tone.x) * tone.w;
    return clamp(t + (c - l) * k, 0.0f, 1.0f);
}

float3 effect_color(EffectIn i, texture2d<float> backdrop) {
    float t = max(-sd_round(i.rect, i.radius, i.p), 0.0f);
    float bezel = i.params[0].x;
    float rim_width = i.params[0].w;
    float2 n = float2(0.0f);
    if (t < bezel || t < 3.0f * rim_width) n = glass_normal(i.p, i.rect, i.radius);
    float2 q = i.p;
    if (t < bezel) q -= n * (i.params[0].y * glass_lens(t, bezel));
    float3 c = glass_tone(backdrop_at(i, backdrop, q), i.params[2]);
    c += (i.params[1].rgb - c) * i.params[1].a;
    if (i.params[0].z > 0.0f && t < 3.0f * rim_width) {
        float r = t / rim_width;
        float a = i.params[0].z * exp(-r * r);
        float l = abs(n.x * i.params[3].x + n.y * i.params[3].y);
        c += (l - c) * a;
    }
    return c;
}
