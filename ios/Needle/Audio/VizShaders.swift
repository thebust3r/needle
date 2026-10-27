/// The visualizer's look, as Metal shaders. A line-for-line port of the website's WebGL shaders
/// (web/site/viz.js), so both versions draw the same thing. Compiled once when the visualizer first shows.
enum VizShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct U {
    float4 res;      // feedback width, height, time, flow
    float4 band;     // bass, mid, high, energy
    float4 look;     // beat, mode, trails, speed
    float4 more;     // mirror, calm, -, -
    float4 c1, c2, c3;
    float4 touch;    // xy position (uv, y up), z swirl strength, w seconds since a tap
    float4 tap;      // xy where the last tap was (uv, y up)
};

struct D { float bands[48]; float wave[128]; };   // the music, straight from the CPU each frame

struct VOut { float4 pos [[position]]; float2 uv; };

// one triangle covering the screen; uv uses y-up (like the web version) for all the math
vertex VOut vizVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
    VOut o; o.pos = float4(p, 0, 1); o.uv = p * 0.5 + 0.5; return o;
}

constexpr sampler lin(filter::linear, address::clamp_to_edge);
constant float PI = 3.14159265;

// textures are stored top-down; our math is y-up
static float3 sampleTex(texture2d<float> t, float2 uv) { return t.sample(lin, float2(uv.x, 1.0 - uv.y)).rgb; }
static float2x2 rot(float a) { float c = cos(a), s = sin(a); return float2x2(float2(c, -s), float2(s, c)); }
static float ss(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
static float gmod(float x, float y) { return x - y * floor(x / y); }
static float hash(float n) { return fract(sin(n) * 43758.5453123); }
static float3 pal(constant U& u, float t) {
    t = fract(t) * 3.0;
    return t < 1.0 ? mix(u.c1.rgb, u.c2.rgb, t) : t < 2.0 ? mix(u.c2.rgb, u.c3.rgb, t - 1.0) : mix(u.c3.rgb, u.c1.rgb, t - 2.0);
}
static float band(constant D& d, float x) { float f = clamp(x, 0.0, 1.0) * 47.0; int i = min(int(f), 46); return mix(d.bands[i], d.bands[i + 1], f - float(i)); }
static float wav(constant D& d, float x) { float f = clamp(x, 0.0, 1.0) * 127.0; int i = min(int(f), 126); return mix(d.wave[i], d.wave[i + 1], f - float(i)); }
static float line(float d, float w) { return w / (abs(d) + w) * ss(w * 14.0, 0.0, abs(d)); }
static float noise(float2 p) {
    float2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    float a = hash(dot(i, float2(1, 57))), b = hash(dot(i + float2(1, 0), float2(1, 57)));
    float c = hash(dot(i + float2(0, 1), float2(1, 57))), d = hash(dot(i + float2(1, 1), float2(1, 57)));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
static float fbm(float2 p) { float s = 0.0, a = 0.5; for (int i = 0; i < 4; i++) { s += a * noise(p); p = p * 2.03 + 7.1; a *= 0.5; } return s; }
static float2 toP(constant U& u, float2 uv) { float2 p = uv - 0.5; p.x *= u.res.x / u.res.y; return p; }
static float2 toUv(constant U& u, float2 p) { p.x /= u.res.x / u.res.y; return p + 0.5; }
static float3 hueTurn(float3 c, float a) { const float3 k = float3(0.57735); float ca = cos(a); return c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca); }

static float3 draw(constant U& u, constant D& data, float2 p, float2 vUv) {
    float3 col = float3(0.0);
    float r = length(p), a = atan2(p.y, p.x);
    float m = u.look.y, flow = u.res.w, bass = u.band.x, mid = u.band.y, high = u.band.z, energy = u.band.w, beat = u.look.x;
    if (u.more.x > 0.5 || m > 5.5) {          // kaleidoscope: fold the picture into mirrored slices
        float seg = m > 5.5 ? 8.0 : 6.0, s = 2.0 * PI / seg;
        float fa = gmod(a + flow * 0.15, s); fa = abs(fa - s * 0.5);
        p = float2(cos(fa), sin(fa)) * r; a = fa;
    }
    if (m < 0.5 || m > 5.5) {                 // Warp Ring
        float R = 0.13 + 0.09 * bass + 0.03 * beat;
        float ang = abs(fract(a / (2.0 * PI) + 0.25) * 2.0 - 1.0);
        float v = band(data, ang);
        float cell = fract(ang * 72.0), bar = ss(0.5, 0.18, abs(cell - 0.5));
        float inSpike = step(R, r) * ss(R + v * 0.30 + 0.004, R + v * 0.30 - 0.01, r);
        col += pal(u, ang * 0.8 + flow * 0.05) * inSpike * bar * (0.55 + v);
        col += pal(u, flow * 0.07) * line(r - R, 0.004) * (0.6 + bass);
        float shock = R * (1.3 + (1.0 - beat) * 1.8);
        col += pal(u, 0.5 + flow * 0.05) * line(r - shock, 0.005) * beat * 0.9;
    }
    if ((m > 0.5 && m < 1.5) || m > 5.5) {    // Prism
        float s = PI / 3.0, fa = gmod(a + flow * 0.25, s); fa = abs(fa - s * 0.5);
        float2 q = float2(cos(fa), sin(fa)) * r;
        float x = q.x / 0.62;
        float amp = (0.05 + energy * 0.22) * x;
        float y = wav(data, fract(x * 0.5 + flow * 0.03)) * amp;
        float on = step(0.0, x) * step(x, 1.0);
        col += pal(u, floor((a + PI) / s) / 6.0 + flow * 0.04) * line(q.y - y, 0.0035) * on * 1.2;
        col += pal(u, 0.3 + flow * 0.03) * line(r - (0.05 + high * 0.12), 0.006) * 0.6;
    }
    if (m > 1.5 && m < 2.5) {                 // Hyperspace
        for (int L = 0; L < 3; L++) {
            float fl = float(L);
            float sectors = 70.0 + fl * 40.0;
            float sec = floor((a + PI) / (2.0 * PI) * sectors);
            float h = hash(sec * 7.13 + fl * 91.7);
            float pos = fract(h + flow * (0.22 + fl * 0.08));
            pos = pos * pos * 0.9;
            float len = 0.015 + 0.10 * energy + 0.05 * beat;
            float center = (sec + 0.5) / sectors * 2.0 * PI - PI;
            float dAng = abs(a - center) * r;
            float along = ss(pos - 0.004, pos, r) * ss(pos + len, pos + len * 0.3, r);
            col += pal(u, h + flow * 0.02) * along * ss(0.004 + pos * 0.006, 0.0, dAng) * (0.6 + high * 1.4) * (0.3 + pos * 2.0);
        }
        col += pal(u, 0.0) * ss(0.08 + bass * 0.08, 0.0, r) * (0.25 + bass * 0.6);
    }
    if (m > 2.5 && m < 3.5) {                 // Melt
        for (int L = 0; L < 3; L++) {
            float fl = float(L);
            float y = 0.36 + fl * 0.14 + wav(data, fract(vUv.x + fl * 0.13)) * (0.06 + mid * 0.22 + beat * 0.04);
            col += pal(u, fl / 3.0 + flow * 0.05) * line(vUv.y - y, 0.0025 + fl * 0.001) * 1.3;
        }
    }
    if (m > 3.5 && m < 4.5) {                 // Equalizer
        float x = abs(vUv.x - 0.5) * 2.0;
        float n = 40.0, cell = floor(x * n), f = fract(x * n);
        float v = band(data, (cell + 0.5) / n);
        float hgt = 0.02 + v * 0.40;
        float d = abs(vUv.y - 0.5);
        float bar = ss(0.42, 0.32, abs(f - 0.5)) * ss(hgt + 0.004, hgt, d);
        col += pal(u, cell / n * 0.7 + flow * 0.04) * bar * (0.5 + v * 0.8);
        col += pal(u, 0.6) * line(d - hgt, 0.003) * ss(0.42, 0.3, abs(f - 0.5)) * 0.8;
    }
    if (m > 4.5 && m < 5.5) {                 // Nebula
        float2 q = p * (1.6 - bass * 0.4);
        float n = fbm(q * 2.0 + float2(flow * 0.4, -flow * 0.25) + fbm(q * 3.0 - flow * 0.2) * 1.5);
        float glow = ss(0.45, 1.0, n) * (0.25 + energy * 1.3);
        col += pal(u, n + flow * 0.05) * glow * 0.5;
        col += pal(u, 0.8) * ss(0.004, 0.0, abs(r - (0.12 + bass * 0.2))) * beat * 0.6;
        float st = step(0.995, hash(floor((p.x + flow * 0.02) * 300.0) + floor(p.y * 300.0) * 311.0)) * high * 1.5;
        col += float3(st);
    }
    if (u.touch.w < 1.2) {                    // tap: a ring of light bursting out from your finger
        float2 tp = toP(u, u.tap.xy);
        float tr = length(p - tp);
        float rad = u.touch.w * 0.55;
        col += pal(u, 0.5 + u.touch.w) * line(tr - rad, 0.006) * (1.0 - u.touch.w / 1.2) * 1.5;
    }
    return col;
}

// Pass 1: last frame moved along the current and faded, then this frame's light on top
fragment float4 vizFeed(VOut in [[stage_in]], constant U& u [[buffer(0)]],
                        texture2d<float> prev [[texture(0)]], constant D& data [[buffer(1)]]) {
    float2 vUv = in.uv;
    float2 p = toP(u, vUv);
    float m = u.look.y, calm = u.more.y, bass = u.band.x, mid = u.band.y, high = u.band.z, beat = u.look.x;
    float speed = u.look.w, flow = u.res.w;
    float zoom = 1.0, turn = 0.0; float2 drift = float2(0.0); float flowAmt = 0.0015;
    if (m < 0.5) { zoom = 1.0 + (0.018 + bass * 0.05 + beat * 0.03) * calm; turn = (0.003 + mid * 0.01) * calm; }
    else if (m < 1.5) { zoom = 1.0 - (0.012 + beat * 0.02) * calm; turn = -(0.004 + high * 0.016) * calm; }
    else if (m < 2.5) { zoom = 1.0 + 0.006 * calm; turn = 0.0012 * calm; }
    else if (m < 3.5) { zoom = 1.0 + (0.008 + bass * 0.015) * calm; drift = float2(0.0, 0.0025 * calm); flowAmt = 0.004; }
    else if (m < 4.5) { zoom = 1.0 + 0.004 * calm; flowAmt = 0.0008; }
    else if (m < 5.5) { zoom = 1.0 + (0.004 + bass * 0.01) * calm; turn = 0.0015 * calm; flowAmt = 0.006; }
    else { zoom = 1.0 + (0.012 + bass * 0.03) * calm; turn = (0.006 + mid * 0.01) * calm; }
    float2 q = rot(turn * speed) * p / (1.0 + (zoom - 1.0) * speed);
    q += float2(sin(q.y * 4.0 + flow * 1.3 + sin(q.x * 3.0 - flow)), cos(q.x * 4.0 - flow * 1.1 + cos(q.y * 3.0 + flow * 0.7))) * flowAmt * calm;
    q += drift * speed;
    float2 tp = toP(u, u.touch.xy);
    float2 d = q - tp;
    float sw = exp(-dot(d, d) * 16.0) * u.touch.z;
    q = tp + rot(sw * 0.35) * d * (1.0 - sw * 0.03);
    float3 pr = sampleTex(prev, toUv(u, q));
    pr = hueTurn(pr, 0.006 * calm + beat * 0.01);
    float3 lit = draw(u, data, p, vUv);
    float3 c = max(max(pr * u.look.z - 0.0025, 0.0), lit) + lit * 0.15;
    return float4(c, 1.0);
}

// Pass 2: onto the screen with a soft glow and a little color fringe on the beat
fragment float4 vizShow(VOut in [[stage_in]], constant U& u [[buffer(0)]], texture2d<float> tex [[texture(0)]]) {
    float2 vUv = in.uv;
    float2 px = 1.0 / u.res.xy;
    float ab = u.look.x * 0.0035;
    float3 c = float3(sampleTex(tex, vUv + float2(ab, 0)).r, sampleTex(tex, vUv).g, sampleTex(tex, vUv - float2(ab, 0)).b);
    float3 b = float3(0.0);
    for (int i = 0; i < 8; i++) {
        float an = float(i) * 0.785398;
        float2 o = float2(cos(an), sin(an));
        b += sampleTex(tex, vUv + o * px * 5.0) + sampleTex(tex, vUv + o * px * 14.0) * 0.6;
    }
    c += b / 12.8 * 0.35;
    float2 v = vUv - 0.5;
    c *= 1.0 - dot(v, v) * 0.55;
    c = c / (1.0 + c * 0.35);
    return float4(pow(c, float3(0.92)), 1.0);
}
"""#
}
