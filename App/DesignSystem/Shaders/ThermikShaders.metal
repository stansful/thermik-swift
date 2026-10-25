//  ThermikShaders.metal — SwiftUI [[stitchable]] shaders for Thermik (MIT).
//  Use via ShaderLibrary.default.<name>(...) with .colorEffect / .distortionEffect / .layerEffect.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - Noise helpers (cheap value noise + 4-octave fBm)

inline float th_hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

inline float th_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = th_hash21(i);
    float b = th_hash21(i + float2(1.0, 0.0));
    float c = th_hash21(i + float2(0.0, 1.0));
    float d = th_hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

inline float th_fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * th_noise(p);
        p = p * 2.03 + 17.0;
        a *= 0.5;
    }
    return v;
}

// Piecewise-linear lookup into a color ramp passed with Shader.Argument.colorArray.
inline half4 th_ramp(device const half4 *ramp, int count, float t) {
    if (count <= 0) { return half4(0.0h); }
    if (count == 1) { return ramp[0]; }
    float x = clamp(t, 0.0, 1.0) * float(count - 1);
    int i = clamp(int(floor(x)), 0, count - 2);
    return mix(ramp[i], ramp[i + 1], half(x - float(i)));
}

// Signed distance from p to a rounded rectangle centred at c with half-size h and radius r.
inline float th_sdRoundRect(float2 p, float2 c, float2 h, float r) {
    float2 q = abs(p - c) - (h - r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// MARK: - 1. heatGlow — animated "heat aura" painted around a card.
// Apply as .colorEffect on a Rectangle that is `spread` pt larger than the card on every side.
//   bounds       : Shader.Argument.boundingRect (float4: x, y, w, h)
//   time         : seconds (TimelineView(.animation))
//   intensity    : 0...1 (map from temperature, 0 = invisible)
//   tint         : glow colour (from the temperature ramp)
//   cornerRadius : card corner radius in pt
//   spread       : distance between the view edge and the card edge in pt
[[ stitchable ]] half4 heatGlow(float2 position, half4 color, float4 bounds,
                               float time, float intensity, half4 tint,
                               float cornerRadius, float spread)
{
    float2 size = bounds.zw;
    float2 center = bounds.xy + size * 0.5;
    float2 halfCard = max(size * 0.5 - spread, float2(1.0));
    float sd = th_sdRoundRect(position, center, halfCard, cornerRadius);

    // Turbulence rises upwards (negative y) faster when hotter.
    float2 uv = (position - bounds.xy) / max(size.x, size.y);
    float speed = 0.25 + 0.65 * intensity;
    float n = th_fbm(uv * 5.0 + float2(0.0, time * speed));

    // Breathing + noisy reach; strongest above the card (heat rises).
    float breathe = 0.88 + 0.12 * sin(time * (1.2 + 1.8 * intensity));
    float above = clamp((center.y - position.y) / halfCard.y, 0.0, 1.0) * 0.35;  // 0 at centre -> 0.35 at top edge
    float reach = spread * (0.35 + 0.65 * intensity) * (0.7 + 0.6 * n + above);
    float glow = exp(-max(sd, 0.0) / max(reach, 1.0) * 2.4) * breathe;
    glow *= (sd < 0.0) ? 0.18 : 1.0;  // faint inside so a translucent card is only lightly tinted
    glow *= 1.0 - smoothstep(spread * 0.55, spread, sd);  // reach exactly 0 at the view edge (no visible box)

    float a = clamp(glow * intensity, 0.0, 1.0) * float(color.a);
    return half4(tint.rgb * half(a), half(a));  // premultiplied
}

// MARK: - 2. heatShimmer — subtle heat-haze distortion (use only when critical).
// Apply as .distortionEffect(..., maxSampleOffset: CGSize(width: amplitude, height: amplitude)).
//   size      : view size (Shader.Argument.float2(size))
//   time      : seconds
//   amplitude : max displacement in pt (0...3 recommended)
[[ stitchable ]] float2 heatShimmer(float2 position, float2 size, float time, float amplitude)
{
    float2 uv = position / max(size, float2(1.0));
    float n  = th_fbm(float2(uv.x * 7.0, uv.y * 2.5 + time * 1.1));
    float n2 = th_fbm(float2(uv.x * 3.0 + 9.0, uv.y * 6.0 + time * 0.8));
    float falloff = 0.35 + 0.65 * (1.0 - uv.y);   // stronger near the top
    return position + float2((n2 - 0.5) * amplitude * 0.6, (n - 0.5) * amplitude) * falloff;
}

// MARK: - 3. thermalField — smooth heat map interpolated from sparse sensors.
// Apply as .colorEffect on the chip-die shape (RoundedRectangle).
//   bounds    : Shader.Argument.boundingRect
//   sensors   : Shader.Argument.floatArray([x0, y0, t0, x1, y1, t1, ...]) with x,y in 0...1 (unit square of the die)
//               and t normalised 0...1 on the temperature scale.
//   ramp      : Shader.Argument.colorArray(ThermalScale.rampColors)
//   power     : inverse-distance-weighting power (2...4; higher = sharper hotspots)
//   time      : seconds (drives a very faint living grain; pass 0 for static)
//   contours  : 0 = off, 1 = draw iso-lines every 10 % of the scale
[[ stitchable ]] half4 thermalField(float2 position, half4 color, float4 bounds,
                                   device const float *sensors, int sensorCount,
                                   device const half4 *ramp, int rampCount,
                                   float power, float time, float contours)
{
    float2 uv = (position - bounds.xy) / max(bounds.zw, float2(1.0));
    int n = sensorCount / 3;
    float wsum = 0.0;
    float tsum = 0.0;
    float tmax = 0.0;
    for (int i = 0; i < n; i++) {
        float2 p = float2(sensors[i * 3], sensors[i * 3 + 1]);
        float  t = sensors[i * 3 + 2];
        float2 d = uv - p;
        float d2 = dot(d, d);
        float w = 1.0 / pow(d2 + 0.0004, power * 0.5);
        wsum += w;
        tsum += w * t;
        tmax = max(tmax, t * exp(-d2 * 90.0));   // local hotspot emphasis
    }
    float t = (n > 0) ? tsum / wsum : 0.0;
    t = max(t, tmax * 0.92);

    // Grain is applied to the colour lookup only, never to the contour test (keeps iso-lines smooth).
    float grain = (th_noise(uv * 48.0 + float2(time * 0.4, 0.0)) - 0.5) * 0.008;
    half4 c = th_ramp(ramp, rampCount, t + grain);

    if (contours > 0.5) {
        float d = abs(fract(t * 10.0 + 0.5) - 0.5);       // 0 exactly on an iso-line (every 10 % of the scale)
        float line = 1.0 - smoothstep(0.012, 0.035, d);
        c.rgb = mix(c.rgb, c.rgb * 0.70h, half(line * 0.45));
    }
    return c * color.a;
}

// MARK: - 4. aurora — slow animated mesh-like gradient for the popover header.
// Apply as .colorEffect on a Rectangle behind the header.
//   bounds : Shader.Argument.boundingRect
//   time   : seconds
//   c0..c2 : three colours (derived from current thermal state)
//   energy : 0...1 animation speed / contrast (map from thermal pressure)
[[ stitchable ]] half4 aurora(float2 position, half4 color, float4 bounds, float time,
                             half4 c0, half4 c1, half4 c2, float energy)
{
    float2 uv = (position - bounds.xy) / max(bounds.zw, float2(1.0));
    float t = time * (0.04 + 0.12 * energy);
    float n1 = th_fbm(uv * float2(1.8, 1.1) + float2(t, -t * 0.6));
    float n2 = th_fbm(uv * float2(1.2, 2.2) - float2(t * 0.7, t * 0.3) + 5.0);
    half4 a = mix(c0, c1, half(smoothstep(0.3, 0.7, n1)));
    half4 b = mix(a, c2, half(smoothstep(0.45, 0.85, n2) * (0.5 + 0.4 * energy)));
    float fade = 1.0 - smoothstep(0.35, 1.0, uv.y);   // melt into content below
    return b * half(fade) * color.a;
}

// MARK: - 5. sparkGlow — layer effect: soft bloom for sparkline strokes (cheap 8-tap).
// Apply as .layerEffect(ShaderLibrary.sparkGlow(.float(radius)), maxSampleOffset: CGSize(width: radius, height: radius)).
[[ stitchable ]] half4 sparkGlow(float2 position, SwiftUI::Layer layer, float radius)
{
    half4 base = layer.sample(position);
    half4 acc = half4(0.0h);
    const float2 dirs[8] = { float2(1,0), float2(-1,0), float2(0,1), float2(0,-1),
                             float2(0.707,0.707), float2(-0.707,0.707), float2(0.707,-0.707), float2(-0.707,-0.707) };
    for (int i = 0; i < 8; i++) {
        acc += layer.sample(position + dirs[i] * radius);
        acc += layer.sample(position + dirs[i] * radius * 0.5);
    }
    acc /= 16.0h;
    return base + acc * 0.6h * (1.0h - base.a);
}
