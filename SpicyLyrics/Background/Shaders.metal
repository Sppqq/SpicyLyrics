#include <metal_stdlib>
using namespace metal;

// A full-screen triangle; `uv` is (0, 0) at the bottom left, like WebGL's texture coordinates.
struct SurfaceVertex {
    float4 position [[position]];
    float2 uv;
};

vertex SurfaceVertex surfaceVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    SurfaceVertex out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = p;
    return out;
}

// MARK: - Noise

static float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float2 mod289(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float3 permute(float3 x) { return mod289(((x * 34.0) + 1.0) * x); }

/// Ashima's 2D simplex noise, as in @kawarp/core.
static float snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = mod289(i);
    float3 p = permute(permute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.y = a0.y * x12.x + h.y * x12.y;
    g.z = a0.z * x12.z + h.z * x12.w;
    return 130.0 * dot(m, g);
}

static float hash3(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

static float hash2(float2 p) {
    float3 q = fract(float3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash2(i), hash2(i + float2(1, 0)), u.x),
               mix(hash2(i + float2(0, 1)), hash2(i + float2(1, 1)), u.x), u.y);
}

static float fbm(float2 p) {
    float sum = 0.0, amplitude = 0.5;
    for (int i = 0; i < 5; i++) {
        sum += amplitude * valueNoise(p);
        p = float2x2(1.6, 1.2, -1.2, 1.6) * p;
        amplitude *= 0.5;
    }
    return sum;
}

// MARK: - Kawarp (the original's background)

struct KawarpUniforms {
    float time;
    float blend;
    float intensity;
    float saturation;
    float dithering;
    float scale;
    float frame;
};

/// @kawarp/core's DOMAIN_WARP + BLEND + OUTPUT passes in one, plus the page's
/// `filter: saturate(2.5) brightness(0.65)`. Drawn at the original's 300×150 and stretched.
fragment half4 kawarpFragment(SurfaceVertex in [[stage_in]],
                              constant KawarpUniforms &u [[buffer(0)]],
                              texture2d<half> current [[texture(0)]],
                              texture2d<half> next [[texture(1)]]) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    // As in a browser, the cover is uploaded without flipping, so it shows upside down.
    float2 vTexCoord = in.uv;
    float2 uv = clamp((vTexCoord - 0.5) / u.scale + 0.5, 0.0, 1.0);

    float t = u.time * 0.05;
    float2 center = uv - 0.5;
    float centerWeight = 1.0 - smoothstep(0.0, 0.7, length(center));
    float n1 = snoise(uv * 0.35 + float2(t, t * 0.7));
    float n2 = snoise(uv * 0.35 + float2(-t * 0.8, t * 0.5) + float2(50.0, 50.0));
    float n3 = snoise(uv * 0.9 + float2(t * 1.2, -t) + float2(100.0, 0.0));
    float n4 = snoise(uv * 0.9 + float2(-t, t * 1.1) + float2(0.0, 100.0));
    float2 warp = float2(n1 * 0.65 + n3 * 0.35, n2 * 0.65 + n4 * 0.35) * centerWeight;
    float2 warped = clamp(uv + warp * u.intensity, 0.0, 1.0);

    half4 color = mix(current.sample(linear, warped), next.sample(linear, warped), half(u.blend));

    float2 vc = vTexCoord - 0.5;
    color.rgb *= half(1.0 - dot(vc, vc) * 0.3);
    half gray = dot(color.rgb, half3(0.299, 0.587, 0.114));
    color.rgb = mix(half3(gray), color.rgb, half(u.saturation));
    float noise = hash3(float3(floor(in.position.xy), u.frame));
    color.rgb += half3(half((noise - 0.5) * u.dithering));
    color.rgb = clamp(color.rgb, half3(0.0), half3(1.0));

    half cssGray = dot(color.rgb, half3(0.213, 0.715, 0.072));
    color.rgb = clamp(mix(half3(cssGray), color.rgb, half(2.5)), half3(0.0), half3(1.0));
    color.rgb *= half(0.65);
    color.a = 1.0;
    return color;
}

// MARK: - Visualizer

struct VisualizerUniforms {
    float3 deep;     // darkest colour of the cover
    float3 vivid;    // its most vivid colour
    float3 accent;   // a second vivid colour, another hue
    float2 resolution;
    float time;      // runs with the music, slows almost to a stop on pause
    float progress;  // 0…1 through the song
    float energy;    // 0 paused … 1 playing, eased
    float style;
};

static float3 stars(float2 p, float time, float density) {
    float2 cell = floor(p * density);
    float2 local = fract(p * density) - 0.5;
    float h = hash2(cell);
    if (h < 0.975) return float3(0.0);
    float2 offset = float2(hash2(cell + 7.1), hash2(cell + 3.7)) - 0.5;
    float d = length(local - offset * 0.6);
    float twinkle = 0.55 + 0.45 * sin(time * (2.0 + h * 4.0) + h * 60.0);
    return float3(smoothstep(0.09, 0.0, d) * twinkle * (h - 0.975) * 40.0);
}

/// "Туманность": coloured smoke folding into itself (domain-warped fbm), with stars behind.
static float3 nebula(float2 p, constant VisualizerUniforms &u) {
    float t = u.time * 0.07;
    float zoom = 1.5 - u.progress * 0.35;
    float angle = t * 0.25;
    float2 r = float2x2(cos(angle), -sin(angle), sin(angle), cos(angle)) * p * zoom;
    float2 q = float2(fbm(r + float2(0.0, t)), fbm(r + float2(5.2, -t * 0.8)));
    float2 w = float2(fbm(r + 3.5 * q + float2(1.7, 9.2) + t * 0.6),
                      fbm(r + 3.5 * q + float2(8.3, 2.8) - t * 0.5));
    float f = fbm(r + 3.0 * w);
    // Layered like light, not mixed like paint: two colours mixed half and half turn to mud.
    float body = pow(smoothstep(0.36, 0.86, f), 1.25);
    float rim = smoothstep(0.6, 1.15, length(w)) * smoothstep(0.35, 0.7, f);
    float core = pow(smoothstep(0.7, 1.0, f), 3.0);
    float3 col = u.deep * 0.12;
    col += u.vivid * body * 0.95;
    col += u.accent * rim * 0.7;
    col += mix(u.vivid, float3(1.0), 0.5) * core * 0.7;
    col += stars(p + float2(t * 0.05, 0.0), u.time, 38.0) * (1.0 - body);
    return col;
}

/// One bar of a made-up spectrum: more in the lows, a hump in the mids, each bar wandering on
/// its own noise (iOS gives no app Spotify's sound, so there is nothing real to measure).
static float barLevel(float i, float count, float t, float energy) {
    float x = i / count;
    float shape = 0.5 * exp(-x * 2.4) + 0.28 * exp(-pow((x - 0.42) * 4.0, 2.0)) + 0.14;
    float slow = valueNoise(float2(i * 0.37, t * 1.7));
    float fast = valueNoise(float2(i * 0.13 + 17.0, t * 4.6));
    float level = shape * (0.3 + 0.95 * slow) + 0.3 * shape * fast;
    return clamp(level, 0.0, 1.0) * (0.2 + 0.8 * energy);
}

/// "Спектр": an equalizer along the bottom, mirrored in a dark floor.
static float3 bars(float2 uv, float2 res, constant VisualizerUniforms &u) {
    const float count = 40.0;
    float margin = 0.06;
    float x = (uv.x - margin) / (1.0 - 2.0 * margin);
    float base = 0.32;
    float3 col = mix(u.deep * 0.05, u.deep * 0.22, smoothstep(0.0, 1.0, uv.y));
    // A soft glow behind the bars, brighter the louder they "play".
    float avg = barLevel(5.0, count, u.time, u.energy);
    col += u.vivid * 0.18 * avg * exp(-abs(uv.y - base - 0.15) * 4.0);
    if (x < 0.0 || x > 1.0) return col;

    float index = floor(x * count);
    float local = fract(x * count);
    float level = barLevel(index, count, u.time, u.energy);
    // A slowly falling cap above each bar, like the classic analysers.
    float peak = max(level, max(barLevel(index, count, u.time - 0.2, u.energy) * 0.97,
                                barLevel(index, count, u.time - 0.4, u.energy) * 0.92));
    float height = 0.5 * level;
    float aspect = res.x / res.y;
    float gap = smoothstep(0.12, 0.2, local) * smoothstep(0.88, 0.8, local);
    float3 tint = mix(u.vivid, u.accent, smoothstep(0.0, 0.5, uv.y - base));

    float above = uv.y - base;
    if (above >= 0.0) {
        float bar = step(above, height) * gap;
        col = mix(col, tint * (0.75 + 0.5 * above / max(height, 0.01)), bar);
        float capY = 0.5 * peak + 0.012;
        float cap = smoothstep(0.006, 0.0, abs(above - capY)) * gap;
        col += mix(u.accent, float3(1.0), 0.4) * cap * 0.9;
        col += tint * 0.25 * gap * exp(-max(above - height, 0.0) * 30.0 / max(aspect, 0.4)) * step(height, above);
    } else {
        // The floor reflection, fading with depth.
        float below = -above;
        float bar = step(below, height * 0.6) * gap;
        col = mix(col, tint * 0.35 * (1.0 - below / 0.25), bar * smoothstep(0.25, 0.0, below));
    }
    col += u.vivid * exp(-abs(above) * 220.0) * 0.5;
    return col;
}

/// Radius of the cover in "Круг", in the shader's units (fraction of the height); the app puts
/// the round cover exactly there.
static float circleRadius(float2 res) {
    return 0.27 * min(res.x, res.y) / res.y;
}

/// "Круг": bars all around the cover, mirrored left and right.
static float3 circleBars(float2 p, float2 res, constant VisualizerUniforms &u) {
    const float count = 36.0;
    float radius = circleRadius(res);
    float r = length(p);
    float3 col = mix(u.deep * 0.25, u.deep * 0.04, smoothstep(0.0, 0.9, r));
    // From the top, the same on both sides.
    float angle = abs(atan2(p.x, p.y)) / M_PI_F;
    float index = floor(angle * count);
    float local = fract(angle * count);
    float level = barLevel(index, count, u.time, u.energy);
    float inner = radius * 1.06;
    float length_ = radius * (0.08 + 0.55 * level);
    float gap = smoothstep(0.15, 0.25, local) * smoothstep(0.85, 0.75, local);
    float t = (r - inner) / max(length_, 1e-3);
    float3 tint = mix(u.vivid, u.accent, clamp(t, 0.0, 1.0));
    float bar = step(inner, r) * step(r, inner + length_) * gap;
    col = mix(col, tint, bar);
    // The cover's halo, breathing with the "music".
    float halo = exp(-max(r - radius, 0.0) * 18.0) * step(radius, r);
    col += u.vivid * halo * (0.25 + 0.5 * level * u.energy);
    return col;
}

fragment half4 visualizerFragment(SurfaceVertex in [[stage_in]], constant VisualizerUniforms &u [[buffer(0)]]) {
    float2 frag = in.uv * u.resolution;
    float2 p = (frag - 0.5 * u.resolution) / u.resolution.y;
    float3 col;
    if (u.style < 0.5) {
        col = nebula(p, u);
    } else if (u.style < 1.5) {
        col = bars(in.uv, u.resolution, u);
    } else {
        col = circleBars(p, u.resolution, u);
    }
    // Dimmer while paused; a soft vignette; a little grain against banding.
    col *= 0.55 + 0.45 * u.energy;
    float2 vc = in.uv - 0.5;
    col *= 1.0 - dot(vc, vc) * 0.9;
    col = col / (1.0 + col * 0.35);
    col += (hash3(float3(frag, floor(u.time * 30.0))) - 0.5) * 0.012;
    return half4(half3(clamp(col, 0.0, 1.0)), 1.0);
}
