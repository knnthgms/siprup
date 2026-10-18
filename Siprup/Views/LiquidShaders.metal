#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Classic iterative "water turbulence" caustic field. Periodic over each tile, so it tiles seamlessly.
static float causticField(float2 uv, float time) {
    const float TAU = 6.28318530718;
    float2 p = fmod(uv * TAU, TAU) - 250.0;
    float2 i = p;
    float c = 1.0;
    const float inten = 0.005;
    for (int n = 0; n < 5; n++) {
        float t = time * (1.0 - (3.5 / float(n + 1)));
        i = p + float2(cos(t - i.x) + sin(t + i.y), sin(t - i.y) + cos(t + i.x));
        c += 1.0 / length(float2(p.x / (sin(i.x + t) / inten), p.y / (cos(i.y + t) / inten)));
    }
    c /= 5.0;
    c = 1.17 - pow(c, 1.4);
    return pow(abs(c), 8.0);
}

/// One pass over the rendered liquid: refraction wobble below the surface, then caustic light
/// applied *through* the drink's own colour (light tinted by what it passes through, not added as white).
[[ stitchable ]] half4 liquidLight(float2 position, SwiftUI::Layer layer, float time, float2 size, float surfaceY, float slope, float strength) {
    float surface = surfaceY - slope * (position.x - size.x * 0.5);
    float depth = position.y - surface;
    float submerged = smoothstep(0.0, 48.0, depth);

    float2 wobble = float2(
        sin(position.y * 0.032 + time * 1.3) + 0.5 * sin(position.y * 0.083 - time * 2.0),
        cos(position.x * 0.041 + time * 1.05)
    ) * 1.5 * submerged * strength;
    half4 base = layer.sample(position + wobble);
    if (depth <= 0.0) { return base; }

    float2 uv = position / 300.0;
    float near = causticField(uv + float2(0.0, time * 0.015), time * 0.42);
    float far = causticField(uv * 1.7 + float2(3.1, 1.3), time * 0.55 + 1.7);
    float k = near * 0.7 + far * 0.3;
    float fadeIn = smoothstep(4.0, 36.0, depth);
    float absorb = mix(1.0, 0.2, smoothstep(0.0, size.y * 0.85, depth));
    float light = clamp(k * fadeIn * absorb, 0.0, 1.0);

    // Brighten proportionally to the liquid colour, plus a whisper of white at the hottest spots.
    half3 lit = base.rgb * (1.0 + half(light) * 0.75) + half3(half(light * light) * 0.18);
    return half4(min(lit, half3(base.a)), base.a);
}
