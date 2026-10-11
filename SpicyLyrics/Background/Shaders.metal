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

/// "Закат": a synthwave sunset. The sun goes down as the song goes on; the grid runs with
/// the music and stops on pause.
static float3 sunset(float2 p, constant VisualizerUniforms &u) {
    float horizon = -0.08;
    float3 col;
    if (p.y > horizon) {
        float h = (p.y - horizon) / 0.6;
        col = mix(mix(u.accent, u.vivid, 0.4) * 0.9, u.deep * 0.25, smoothstep(0.0, 1.0, h));
        col += stars(p, u.time, 46.0) * smoothstep(0.25, 0.8, h) * 0.8;

        float sunY = mix(0.26, horizon - 0.06, u.progress);
        float radius = 0.2;
        float2 d = p - float2(0.0, sunY);
        float dist = length(d);
        // Warm at the top whatever the cover: a sunset should glow like one.
        float3 sunColor = mix(u.vivid * 1.15, mix(u.accent, float3(1.0, 0.82, 0.45), 0.7) * 1.25,
                              smoothstep(-radius, radius, d.y));
        // Bands cut out of the lower half, drifting down.
        float below = clamp(-d.y / radius, 0.0, 1.0);
        float band = fract(d.y * 16.0 + u.time * 0.35);
        float cut = step(band, below * 0.55) * step(d.y, 0.0);
        float disc = smoothstep(radius, radius - 0.006, dist) * (1.0 - cut);
        col = mix(col, sunColor, disc);
        col += sunColor * exp(-max(dist - radius, 0.0) * 9.0) * 0.35;

        // Mountains in front of the sun.
        float ridge = horizon + 0.035 + 0.07 * fbm(float2(p.x * 2.4 + 3.0, 1.0)) * (0.6 + 0.4 * abs(p.x) * 2.0);
        float mountain = smoothstep(ridge + 0.004, ridge, p.y);
        float3 rock = u.deep * 0.18 + u.vivid * 0.06;
        col = mix(col, rock, mountain);
        col += u.vivid * smoothstep(0.012, 0.0, abs(p.y - ridge)) * 0.35 * mountain;
    } else {
        float z = horizon - p.y;
        float depth = 0.32 / max(z, 0.002);
        float2 g = float2(p.x * depth, depth + u.time * 1.4);
        float2 fw = fwidth(g);
        float2 lines = abs(fract(g) - 0.5) / max(fw, 1e-4);
        float grid = 1.0 - min(min(lines.x, lines.y) * 0.6, 1.0);
        float fade = exp(-depth * 0.045);
        col = u.deep * 0.08 + mix(u.vivid, u.accent, 0.35) * grid * fade * 1.4;
        // The sun's reflection.
        col += mix(u.accent, u.vivid, 0.5) * exp(-abs(p.x) * 7.0) * exp(-z * 6.0) * 0.35;
    }
    col += mix(u.vivid, u.accent, 0.5) * exp(-abs(p.y - horizon) * 40.0) * 0.45;
    return col;
}

/// "Тоннель": flying down a tunnel of light; it speeds up as the song goes on.
static float3 tunnel(float2 p, constant VisualizerUniforms &u) {
    float r = max(length(p), 1e-3);
    float a = atan2(p.y, p.x);
    float twist = sin(u.time * 0.21) * 0.6;
    float depth = 0.32 / r + u.time * (0.9 + u.progress * 0.8);
    float around = a / (2.0 * M_PI_F) * 12.0 + twist / r * 0.15;
    // Rings along the tunnel, ribs around it: thin glowing lines, wider far away.
    float2 g = float2(depth * 4.0, around);
    float2 fw = fwidth(g);
    float2 lines = abs(fract(g) - 0.5) / max(fw * 1.6, 1e-4);
    float ring = 1.0 - min(lines.x, 1.0);
    float rib = 1.0 - min(lines.y, 1.0);
    float swirl = fbm(float2(depth * 0.6, around * 0.25));
    float3 wall = mix(u.vivid, u.accent, 0.5 + 0.5 * sin(depth * 0.7));
    float fade = smoothstep(0.0, 0.35, r);
    float3 col = u.deep * 0.1 + wall * swirl * 0.35 * fade;
    col += wall * (ring * 0.9 + rib * 0.35) * fade * smoothstep(0.02, 0.2, r);
    // The light at the end.
    col += mix(u.accent, float3(1.0), 0.6) * exp(-r * 9.0) * 1.2;
    return col;
}

fragment half4 visualizerFragment(SurfaceVertex in [[stage_in]], constant VisualizerUniforms &u [[buffer(0)]]) {
    float2 frag = in.uv * u.resolution;
    float2 p = (frag - 0.5 * u.resolution) / u.resolution.y;
    float3 col;
    if (u.style < 0.5) {
        col = nebula(p, u);
    } else if (u.style < 1.5) {
        col = sunset(p, u);
    } else {
        col = tunnel(p, u);
    }
    // Dimmer while paused; a soft vignette; a little grain against banding.
    col *= 0.55 + 0.45 * u.energy;
    float2 vc = in.uv - 0.5;
    col *= 1.0 - dot(vc, vc) * 0.9;
    col = col / (1.0 + col * 0.35);
    col += (hash3(float3(frag, floor(u.time * 30.0))) - 0.5) * 0.012;
    return half4(half3(clamp(col, 0.0, 1.0)), 1.0);
}
