/* Needle visualizer: an original, Neon-spirited light show drawn on the graphics chip (WebGL),
   at full screen resolution. Same look and rules as the iPhone app (ios/Needle/Audio/VizShaders.swift).
   - every frame melts into the next (feedback trails) and drifts along a slow "current", so it flows
   - bass, mids and highs each drive different things; quiet songs are boosted so they react too
   - styles, color themes, reactivity, trails, speed, kaleidoscope, and touch (drag to swirl, tap to burst)
   - flashes are capped at 3 per second and kept soft (WCAG 2.3.1); Reduce Motion slows it and turns flashes off */
"use strict";

const Viz = (() => {
  const MODES = [
    { id: "tunnel", name: "Warp Ring" },
    { id: "prism", name: "Prism" },
    { id: "hyper", name: "Hyperspace" },
    { id: "melt", name: "Melt" },
    { id: "bars", name: "Equalizer" },
    { id: "nebula", name: "Nebula" },
    { id: "mandala", name: "Mandala" },
  ];
  const THEMES = {
    album: { name: "Album Colors" },
    neon: { name: "Neon", c: [[0.1, 0.95, 1], [1, 0.2, 0.85], [0.6, 1, 0.2]] },
    fire: { name: "Fire", c: [[1, 0.25, 0.05], [1, 0.62, 0.1], [1, 0.95, 0.5]] },
    ice: { name: "Ice", c: [[0.2, 0.55, 1], [0.35, 0.95, 1], [0.92, 0.97, 1]] },
    vapor: { name: "Vaporwave", c: [[1, 0.42, 0.75], [0.62, 0.38, 1], [0.25, 0.95, 0.9]] },
    toxic: { name: "Toxic", c: [[0.45, 1, 0.1], [0.1, 1, 0.55], [0.95, 1, 0.2]] },
    mono: { name: "Mono", c: [[1, 1, 1], [0.75, 0.78, 0.85], [0.5, 0.52, 0.6]] },
  };
  const DEFAULTS = { theme: "album", intensity: 1, trails: 0.6, speed: 1, mirror: false };
  const BINS = 48;
  const reducedMQ = window.matchMedia ? matchMedia("(prefers-reduced-motion: reduce)") : { matches: false };
  const reduced = () => reducedMQ.matches;
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));

  let modeIndex = clamp(+store.get("vizMode", 0) || 0, 0, MODES.length - 1);
  let auto = store.get("vizAuto", true);
  const settings = Object.assign({}, DEFAULTS, store.get("vizSettings", {}));

  // ---------------- listening ----------------
  const levels = new Float32Array(BINS), peaks = new Float32Array(BINS).fill(0.3), shown = new Float32Array(BINS);
  const waveOut = new Float32Array(128);
  let freq = null, wave = null, live = false;
  let bass = 0, mid = 0, high = 0, energy = 0, rawBass = 0;
  let bassAvg = 0, longAvg = 0, lastBeat = 0, beat = 0, quietSince = 0, lastSwitch = 0, flow = 0;
  const flashTimes = [];
  let flash = 0;
  let baseHue = 175;
  const stats = { frames: 0, drawMs: [], intervals: [], beats: 0, flashes: 0, flashLog: [], modeSwitches: 0, quality: 1, resizes: 0 };

  function readAudio(t, dt) {
    const k = dt / 16.67;
    const a = audio.vizAnalyser;
    live = !!(a && player.playing && player.el && player.el.routed && audio.ctx && audio.ctx.state === "running");
    if (live) {
      if (!freq || freq.length !== a.frequencyBinCount) { freq = new Float32Array(a.frequencyBinCount); wave = new Float32Array(a.fftSize); }
      a.getFloatFrequencyData(freq);
      a.getFloatTimeDomainData(wave);
      const fs = audio.ctx.sampleRate, n = freq.length, binHz = fs / 2 / n;
      for (let b = 0; b < BINS; b++) {
        const f0 = 30 * Math.pow(16000 / 30, b / BINS), f1 = 30 * Math.pow(16000 / 30, (b + 1) / BINS);
        const i0 = Math.max(1, Math.floor(f0 / binHz)), i1 = Math.max(i0 + 1, Math.min(n, Math.floor(f1 / binHz)));
        let peak = -200;
        for (let i = i0; i < i1; i++) if (freq[i] > peak) peak = freq[i];
        const v = clamp((peak + 85) / 65, 0, 1);
        levels[b] = v > levels[b] ? v : levels[b] * 0.82 + v * 0.18;
      }
      for (let i = 0; i < 128; i++) waveOut[i] = wave[Math.floor(i / 127 * (wave.length - 1))];
    } else {
      for (let b = 0; b < BINS; b++) levels[b] = 0.1 + 0.07 * Math.sin(t * 0.0011 + b * 0.35) * Math.sin(t * 0.0007 + b * 0.13);
      for (let i = 0; i < 128; i++) waveOut[i] = Math.sin(i / 127 * Math.PI * 4 + t * 0.002) * 0.12;
    }
    prepare(t, k);
  }

  /** Turns raw levels into what's drawn: quiet songs boosted, hits instant, fall-offs smooth. Also beats, flashes, drops. */
  function prepare(t, k) {
    const I = settings.intensity;
    for (let b = 0; b < BINS; b++) {
      const v = levels[b];
      if (!live) { shown[b] = shown[b] * Math.pow(0.9, k) + v * 0.6 * (1 - Math.pow(0.9, k)); continue; }   // paused: calm idle motion only
      peaks[b] = Math.max(v, peaks[b] * Math.pow(0.996, k), 0.12);              // each band's recent loudest
      const norm = clamp(v * 0.3 + (v / peaks[b]) * 0.7 * Math.min(1, v * 10), 0, 1.2) * I;   // boost quiet songs, keep silence dark
      shown[b] = norm > shown[b] ? norm : shown[b] * Math.pow(0.86, k) + norm * (1 - Math.pow(0.86, k));
    }
    let s = 0; for (let b = 0; b < 6; b++) s += levels[b]; rawBass = s / 6;
    s = 0; for (let b = 0; b < 6; b++) s += shown[b]; bass = s / 6;
    s = 0; for (let b = 6; b < 25; b++) s += shown[b]; mid = s / 19;
    s = 0; for (let b = 25; b < BINS; b++) s += shown[b]; high = s / (BINS - 25);
    energy = (bass * 2 + mid + high) / 4;

    // beat = bass jumping clearly above its recent average (on the raw level, so safety limits never change)
    bassAvg = bassAvg * 0.9 + rawBass * 0.1;
    longAvg = longAvg * 0.995 + rawBass * 0.005;
    if (live && rawBass > bassAvg * 1.12 + 0.035 && rawBass > 0.28 && t - lastBeat > 240) {
      lastBeat = t; beat = 1; stats.beats++; onBeat(t);
    }
    beat *= Math.pow(reduced() ? 0.82 : 0.9, k);
    flash *= Math.pow(0.8, k);
    if (live && rawBass < longAvg * 0.6) { if (!quietSince) quietSince = t; }
    else if (quietSince) {
      if (auto && t - quietSince > 1500 && rawBass > longAvg * 1.3) switchMode(t);
      quietSince = 0;
    }
    // the slow current everything drifts along: always moving, faster when the music is busy
    flow += (k / 60) * (0.25 + 1.6 * energy) * settings.speed * (reduced() ? 0.35 : 1);
    baseHue += (reduced() ? 0.05 : 0.15) * k;
  }

  function onBeat(t) {
    while (flashTimes.length && t - flashTimes[0] > 1000) flashTimes.shift();
    if (!reduced() && flashTimes.length < 3 && energy > 0.35) {
      flashTimes.push(t); flash = 1; stats.flashes++;
      stats.flashLog.push(t); if (stats.flashLog.length > 100) stats.flashLog.shift();
    }
    if (auto && t - lastSwitch > 45000) switchMode(t);
  }

  function switchMode(t) {
    modeIndex = (modeIndex + 1) % MODES.length;
    lastSwitch = t;
    stats.modeSwitches++;
    if (api.onModeChange) api.onModeChange(MODES[modeIndex]);
  }

  // ---------------- colors ----------------
  function hsv(h, s, v) {
    h = ((h % 360) + 360) % 360 / 60;
    const c = v * s, x = c * (1 - Math.abs((h % 2) - 1)), m = v - c;
    const [r, g, b] = h < 1 ? [c, x, 0] : h < 2 ? [x, c, 0] : h < 3 ? [0, c, x] : h < 4 ? [0, x, c] : h < 5 ? [x, 0, c] : [c, 0, x];
    return [r + m, g + m, b + m];
  }
  function palette() {
    const th = THEMES[settings.theme];
    if (th && th.c) return th.c;
    return [hsv(baseHue, 0.85, 1), hsv(baseHue + 120, 0.85, 1), hsv(baseHue + 220, 0.75, 1)];   // from the album, drifting
  }

  // ---------------- shaders ----------------
  const VERT = `attribute vec2 aPos; varying vec2 vUv; void main(){ vUv = aPos * 0.5 + 0.5; gl_Position = vec4(aPos, 0.0, 1.0); }`;
  const COMMON = `
precision highp float;
varying vec2 vUv;
uniform vec2 uRes;
uniform float uTime, uFlow, uBass, uMid, uHigh, uEnergy, uBeat, uMode, uTrails, uSpeed, uMirror, uCalm;
uniform vec3 uC1, uC2, uC3;
uniform vec4 uTouch;      // xy position (uv), z = swirl strength, w = seconds since a tap
uniform vec2 uTap;        // where the last tap was (uv)
uniform sampler2D uData;    // row 0: the 48 bands, row 1: 128 waveform samples (one lookup per pixel)
const float PI = 3.14159265;
mat2 rot(float a){ float c = cos(a), s = sin(a); return mat2(c, -s, s, c); }
float ss(float a, float b, float x){ float t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
float gmod(float x, float y){ return x - y * floor(x / y); }
float hash(float n){ return fract(sin(n) * 43758.5453123); }
vec3 pal(float t){ t = fract(t) * 3.0; return t < 1.0 ? mix(uC1, uC2, t) : t < 2.0 ? mix(uC2, uC3, t - 1.0) : mix(uC3, uC1, t - 2.0); }
float band(float x){ return texture2D(uData, vec2((clamp(x, 0.0, 1.0) * 47.0 + 0.5) / 128.0, 0.25)).r * 1.25; }
float wav(float x){ return texture2D(uData, vec2((clamp(x, 0.0, 1.0) * 127.0 + 0.5) / 128.0, 0.75)).r * 2.0 - 1.0; }
float line(float d, float w){ return w / (abs(d) + w) * ss(w * 14.0, 0.0, abs(d)); }
float noise(vec2 p){ vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
  float a = hash(dot(i, vec2(1.0, 57.0))), b = hash(dot(i + vec2(1.0, 0.0), vec2(1.0, 57.0)));
  float c = hash(dot(i + vec2(0.0, 1.0), vec2(1.0, 57.0))), d = hash(dot(i + vec2(1.0, 1.0), vec2(1.0, 57.0)));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y); }
float fbm(vec2 p){ float s = 0.0, a = 0.5; for (int i = 0; i < 4; i++) { s += a * noise(p); p = p * 2.03 + 7.1; a *= 0.5; } return s; }
`;

  // Pass 1: last frame, moved along the current (zoom, turn, flow, touch swirl), faded; then this frame's light added on top.
  const FEED = COMMON + `
uniform sampler2D uPrev;
vec2 toP(vec2 uv){ vec2 p = uv - 0.5; p.x *= uRes.x / uRes.y; return p; }
vec2 toUv(vec2 p){ p.x /= uRes.x / uRes.y; return p + 0.5; }
vec3 hueTurn(vec3 c, float a){ const vec3 k = vec3(0.57735); float ca = cos(a); return c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca); }

vec3 draw(vec2 p){
  vec3 col = vec3(0.0);
  float r = length(p), a = atan(p.y, p.x);
  float m = uMode;
  if (uMirror > 0.5 || m > 5.5) {   // kaleidoscope: fold the picture into mirrored slices
    float seg = m > 5.5 ? 8.0 : 6.0, s = 2.0 * PI / seg;
    float fa = gmod(a + uFlow * 0.15, s); fa = abs(fa - s * 0.5);
    p = vec2(cos(fa), sin(fa)) * r; a = fa;
  }
  if (m < 0.5 || m > 5.5) {   // Warp Ring: the spectrum as spikes around a ring that breathes with the bass
    float R = 0.13 + 0.09 * uBass + 0.03 * uBeat;
    float ang = abs(fract(a / (2.0 * PI) + 0.25) * 2.0 - 1.0);
    float v = band(ang);
    float bars = 72.0, cell = fract(ang * bars), bar = ss(0.5, 0.18, abs(cell - 0.5));
    float inSpike = step(R, r) * ss(R + v * 0.30 + 0.004, R + v * 0.30 - 0.01, r);
    col += pal(ang * 0.8 + uFlow * 0.05) * inSpike * bar * (0.55 + v);
    col += pal(uFlow * 0.07) * line(r - R, 0.004) * (0.6 + uBass);
    float shock = R * (1.3 + (1.0 - uBeat) * 1.8);
    col += pal(0.5 + uFlow * 0.05) * line(r - shock, 0.005) * uBeat * 0.9;
  }
  if ((m > 0.5 && m < 1.5) || m > 5.5) {   // Prism: the waveform, mirrored into a six-way star
    float s = PI / 3.0, fa = gmod(a + uFlow * 0.25, s); fa = abs(fa - s * 0.5);
    vec2 q = vec2(cos(fa), sin(fa)) * r;
    float x = q.x / 0.62;
    float amp = (0.05 + uEnergy * 0.22) * x;
    float y = wav(fract(x * 0.5 + uFlow * 0.03)) * amp;
    float on = step(0.0, x) * step(x, 1.0);
    col += pal(floor((a + PI) / s) / 6.0 + uFlow * 0.04) * line(q.y - y, 0.0035) * on * 1.2;
    col += pal(0.3 + uFlow * 0.03) * line(r - (0.05 + uHigh * 0.12), 0.006) * 0.6;
  }
  if (m > 1.5 && m < 2.5) {   // Hyperspace: stars streaking out from the middle, faster with the music
    for (int L = 0; L < 3; L++) {
      float fl = float(L);
      float sectors = 70.0 + fl * 40.0;
      float sec = floor((a + PI) / (2.0 * PI) * sectors);
      float h = hash(sec * 7.13 + fl * 91.7);
      float pos = fract(h + uFlow * (0.22 + fl * 0.08));
      pos = pos * pos * 0.9;
      float len = 0.015 + 0.10 * uEnergy + 0.05 * uBeat;
      float center = (sec + 0.5) / sectors * 2.0 * PI - PI;
      float dAng = abs(a - center) * r;
      float along = ss(pos - 0.004, pos, r) * ss(pos + len, pos + len * 0.3, r);
      col += pal(h + uFlow * 0.02) * along * ss(0.004 + pos * 0.006, 0.0, dAng) * (0.6 + uHigh * 1.4) * (0.3 + pos * 2.0);
    }
    col += pal(0.0) * ss(0.08 + uBass * 0.08, 0.0, r) * (0.25 + uBass * 0.6);
  }
  if (m > 2.5 && m < 3.5) {   // Melt: three waveform lines that drip down through the trails
    vec2 uv = vUv;
    for (int L = 0; L < 3; L++) {
      float fl = float(L);
      float y = 0.36 + fl * 0.14 + wav(fract(uv.x + fl * 0.13)) * (0.06 + uMid * 0.22 + uBeat * 0.04);
      col += pal(fl / 3.0 + uFlow * 0.05) * line(uv.y - y, 0.0025 + fl * 0.001) * 1.3;
    }
  }
  if (m > 3.5 && m < 4.5) {   // Equalizer: crisp mirrored bars from the middle, with a glow
    vec2 uv = vUv;
    float x = abs(uv.x - 0.5) * 2.0;
    float n = 40.0, cell = floor(x * n), f = fract(x * n);
    float v = band((cell + 0.5) / n);
    float hgt = 0.02 + v * 0.40;
    float d = abs(uv.y - 0.5);
    float bar = ss(0.42, 0.32, abs(f - 0.5)) * ss(hgt + 0.004, hgt, d);
    col += pal(cell / n * 0.7 + uFlow * 0.04) * bar * (0.5 + v * 0.8);
    col += pal(0.6) * line(d - hgt, 0.003) * ss(0.42, 0.3, abs(f - 0.5)) * 0.8;
  }
  if (m > 4.5 && m < 5.5) {   // Nebula: glowing clouds pushed around by the current and the bass
    vec2 q = p * (1.6 - uBass * 0.4);
    float n = fbm(q * 2.0 + vec2(uFlow * 0.4, -uFlow * 0.25) + fbm(q * 3.0 - uFlow * 0.2) * 1.5);
    float glow = ss(0.45, 1.0, n) * (0.25 + uEnergy * 1.3);
    col += pal(n + uFlow * 0.05) * glow * 0.5;
    col += pal(0.8) * ss(0.004, 0.0, abs(r - (0.12 + uBass * 0.2))) * uBeat * 0.6;
    float st = step(0.995, hash(floor((p.x + uFlow * 0.02) * 300.0) + floor(p.y * 300.0) * 311.0)) * uHigh * 1.5;
    col += vec3(st);
  }
  // tap: a ring of light bursting out from your finger
  if (uTouch.w < 1.2) {
    vec2 tp = toP(uTap);
    float tr = length(p - tp);
    float rad = uTouch.w * 0.55;
    col += pal(0.5 + uTouch.w) * line(tr - rad, 0.006) * (1.0 - uTouch.w / 1.2) * 1.5;
  }
  return col;
}

void main(){
  vec2 p = toP(vUv);
  float m = uMode, calm = uCalm;
  // how each style moves its trails
  float zoom = 1.0, turn = 0.0; vec2 drift = vec2(0.0); float flowAmt = 0.0015;
  if (m < 0.5) { zoom = 1.0 + (0.018 + uBass * 0.05 + uBeat * 0.03) * calm; turn = (0.003 + uMid * 0.01) * calm; }
  else if (m < 1.5) { zoom = 1.0 - (0.012 + uBeat * 0.02) * calm; turn = -(0.004 + uHigh * 0.016) * calm; }
  else if (m < 2.5) { zoom = 1.0 + 0.006 * calm; turn = 0.0012 * calm; }
  else if (m < 3.5) { zoom = 1.0 + (0.008 + uBass * 0.015) * calm; drift = vec2(0.0, 0.0025 * calm); flowAmt = 0.004; }
  else if (m < 4.5) { zoom = 1.0 + 0.004 * calm; drift = vec2(0.0, 0.0); flowAmt = 0.0008; }
  else if (m < 5.5) { zoom = 1.0 + (0.004 + uBass * 0.01) * calm; turn = 0.0015 * calm; flowAmt = 0.006; }
  else { zoom = 1.0 + (0.012 + uBass * 0.03) * calm; turn = (0.006 + uMid * 0.01) * calm; }
  vec2 q = rot(turn * uSpeed) * p / (1.0 + (zoom - 1.0) * uSpeed);
  // the current: a smooth swirl field that's always moving
  q += vec2(sin(q.y * 4.0 + uFlow * 1.3 + sin(q.x * 3.0 - uFlow)), cos(q.x * 4.0 - uFlow * 1.1 + cos(q.y * 3.0 + uFlow * 0.7))) * flowAmt * calm;
  q += drift * uSpeed;
  // your finger swirls it
  vec2 tp = toP(uTouch.xy);
  vec2 d = q - tp;
  float sw = exp(-dot(d, d) * 16.0) * uTouch.z;
  q = tp + rot(sw * 0.35) * d * (1.0 - sw * 0.03);
  vec3 prev = texture2D(uPrev, toUv(q)).rgb;
  prev = hueTurn(prev, 0.006 * calm + uBeat * 0.01);
  vec3 lit = draw(p);
  // new light takes over where it's brighter than the fading trail (plus a little glow on top),
  // so trails never pile up into a white-out
  vec3 c = max(max(prev * uTrails - 0.0025, 0.0), lit) + lit * 0.15;
  gl_FragColor = vec4(c, 1.0);
}`;

  // Pass 2: onto the screen with a soft glow and a little color fringe on the beat.
  const SHOW = COMMON + `
uniform sampler2D uTex;
void main(){
  vec2 px = 1.0 / uRes;
  float ab = uBeat * 0.0035;
  vec3 c = vec3(texture2D(uTex, vUv + vec2(ab, 0.0)).r, texture2D(uTex, vUv).g, texture2D(uTex, vUv - vec2(ab, 0.0)).b);
  vec3 b = vec3(0.0);
  for (int i = 0; i < 8; i++) {
    float an = float(i) * 0.785398;
    vec2 o = vec2(cos(an), sin(an));
    b += texture2D(uTex, vUv + o * px * 5.0).rgb + texture2D(uTex, vUv + o * px * 14.0).rgb * 0.6;
  }
  c += b / 12.8 * 0.35;
  vec2 v = vUv - 0.5;
  c *= 1.0 - dot(v, v) * 0.55;
  c = c / (1.0 + c * 0.35);                     // keep bright parts glowing instead of clipping
  gl_FragColor = vec4(pow(c, vec3(0.92)), 1.0);
}`;

  // ---------------- WebGL ----------------
  const renderers = new WeakMap();
  function makeRenderer(canvas) {
    const gl = canvas.getContext("webgl", { alpha: false, antialias: false, premultipliedAlpha: false, preserveDrawingBuffer: true, powerPreference: "high-performance" });
    if (!gl) return null;
    const half = gl.getExtension("OES_texture_half_float");
    const halfColor = gl.getExtension("EXT_color_buffer_half_float");
    gl.getExtension("OES_texture_half_float_linear");
    const texType = half && halfColor ? half.HALF_FLOAT_OES : gl.UNSIGNED_BYTE;
    function compile(type, src) {
      const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
      return s;
    }
    function program(frag) {
      const p = gl.createProgram();
      gl.attachShader(p, compile(gl.VERTEX_SHADER, VERT)); gl.attachShader(p, compile(gl.FRAGMENT_SHADER, frag));
      gl.bindAttribLocation(p, 0, "aPos"); gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
      const u = {}, n = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS);
      for (let i = 0; i < n; i++) { const info = gl.getActiveUniform(p, i); const name = info.name.replace(/\[0\]$/, ""); u[name] = gl.getUniformLocation(p, info.name); }
      return { p, u };
    }
    const feed = program(FEED), show = program(SHOW);
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    const targets = [0, 1].map(() => ({ tex: gl.createTexture(), fb: gl.createFramebuffer() }));
    const dataTex = gl.createTexture(), dataBuf = new Uint8Array(128 * 2);
    gl.bindTexture(gl.TEXTURE_2D, dataTex);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.LUMINANCE, 128, 2, 0, gl.LUMINANCE, gl.UNSIGNED_BYTE, dataBuf);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    function upload(bands, wv) {
      for (let i = 0; i < 128; i++) {
        dataBuf[i] = i < 48 ? Math.max(0, Math.min(255, Math.round(bands[i] / 1.25 * 255))) : 0;
        dataBuf[128 + i] = Math.max(0, Math.min(255, Math.round((wv[i] * 0.5 + 0.5) * 255)));
      }
      gl.activeTexture(gl.TEXTURE1);
      gl.bindTexture(gl.TEXTURE_2D, dataTex);
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 128, 2, gl.LUMINANCE, gl.UNSIGNED_BYTE, dataBuf);
      gl.activeTexture(gl.TEXTURE0);
    }
    let tw = 0, th = 0, cur = 0;
    function size(w, h) {
      if (w === tw && h === th) return;
      tw = w; th = h;
      for (const t of targets) {
        gl.bindTexture(gl.TEXTURE_2D, t.tex);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, texType, null);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.bindFramebuffer(gl.FRAMEBUFFER, t.fb);
        gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t.tex, 0);
        gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT);
      }
      stats.resizes++;
    }
    function set(prog, U) {
      const u = prog.u;
      gl.uniform2f(u.uRes, tw, th);
      for (const [k, v] of Object.entries(U)) {
        const loc = u[k]; if (!loc) continue;
        if (typeof v === "number") gl.uniform1f(loc, v);
        else if (v.length === 3) gl.uniform3fv(loc, v);
        else if (v.length === 4 && k === "uTouch") gl.uniform4fv(loc, v);
        else if (v.length === 2) gl.uniform2fv(loc, v);
      }
    }
    return {
      gl, highPrecision: texType !== gl.UNSIGNED_BYTE,
      draw(w, h, U, bands, wv) {
        size(w, h);
        upload(bands, wv);
        const src = targets[cur], dst = targets[1 - cur];
        gl.viewport(0, 0, w, h);
        gl.useProgram(feed.p);
        gl.bindFramebuffer(gl.FRAMEBUFFER, dst.fb);
        gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, src.tex);
        gl.uniform1i(feed.u.uPrev, 0);
        gl.uniform1i(feed.u.uData, 1);
        set(feed, U);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        gl.viewport(0, 0, canvas.width, canvas.height);
        gl.useProgram(show.p);
        gl.bindTexture(gl.TEXTURE_2D, dst.tex);
        gl.uniform1i(show.u.uTex, 0);
        if (show.u.uData) gl.uniform1i(show.u.uData, 1);
        set(show, U);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
        cur = 1 - cur;
      },
    };
  }

  // ---------------- frame loop ----------------
  let canvas = null, R = null, flashEl = null, lastFlashOpacity = -1;
  let raf = 0, running = false, lastT = 0, quality = 1, slowSince = 0, fastSince = 0;
  let listenTimer = 0, lastListen = 0;
  // drawing-size limit: 1 = full screen resolution. Tests on machines without a graphics chip lower it.
  const qualityCap = clamp(+store.get("vizCap", 1) || 1, 0.1, 1);
  /** Listening runs on its own steady clock, so beats are caught even if drawing slows down. */
  function listen() {
    const t = performance.now();
    const dt = lastListen ? Math.min(60, t - lastListen) : 16.7;
    lastListen = t;
    readAudio(t, dt);
  }
  const touch = { x: 0.5, y: 0.5, swirl: 0, tapAt: -10, tapX: 0.5, tapY: 0.5 };

  function resize() {
    const dpr = window.devicePixelRatio || 1;
    const cw = canvas.clientWidth || 300, ch = canvas.clientHeight || 300;
    const q = quality * qualityCap;
    const nw = Math.max(64, Math.round(cw * dpr * q)), nh = Math.max(64, Math.round(ch * dpr * q));
    if (canvas.width !== nw || canvas.height !== nh) { canvas.width = nw; canvas.height = nh; }
  }

  function frame(t) {
    if (!running) return;
    raf = requestAnimationFrame(frame);
    if (document.hidden || !canvas || !canvas.isConnected || !R) return;
    const dt = lastT ? Math.min(60, t - lastT) : 16.7;
    lastT = t;
    const t0 = performance.now();
    resize();
    touch.swirl *= Math.pow(0.9, dt / 16.67);
    const c = palette();
    R.draw(canvas.width, canvas.height, {
      uTime: t / 1000, uFlow: flow, uBass: bass, uMid: mid, uHigh: high, uEnergy: energy, uBeat: reduced() ? beat * 0.4 : beat,
      uMode: modeIndex, uTrails: 0.80 + settings.trails * 0.17, uSpeed: settings.speed, uMirror: settings.mirror ? 1 : 0, uCalm: reduced() ? 0.35 : 1,
      uC1: c[0], uC2: c[1], uC3: c[2],
      uTouch: [touch.x, 1 - touch.y, touch.swirl, (t / 1000) - touch.tapAt], uTap: [touch.tapX, 1 - touch.tapY],
    }, shown, waveOut);
    if (flashEl) {
      const o = flash > 0.02 ? +(flash * 0.18).toFixed(3) : 0;
      if (o !== lastFlashOpacity) {
        flashEl.style.opacity = o;
        if (o && !lastFlashOpacity) { const p = c[1]; flashEl.style.background = `rgb(${p.map((v) => Math.round(v * 255)).join(",")})`; }
        lastFlashOpacity = o;
      }
    }
    governor(t, performance.now() - t0, dt);
  }

  /** Keeps it smooth: draws a little smaller if the device can't keep up, back to full when it can. */
  function governor(t, ms, dt) {
    stats.frames++;
    stats.drawMs.push(ms); if (stats.drawMs.length > 240) stats.drawMs.shift();
    stats.intervals.push(dt); if (stats.intervals.length > 240) stats.intervals.shift();
    const recent = stats.intervals.slice(-30);
    const avgDt = recent.reduce((a, b) => a + b, 0) / recent.length;
    if (avgDt > 21) {
      fastSince = 0;
      if (!slowSince) slowSince = t;
      if (t - slowSince > 1000 && quality > 0.5) { quality = Math.max(0.5, quality - 0.1); slowSince = t; }
    } else if (avgDt < 17.5) {
      slowSince = 0;
      if (!fastSince) fastSince = t;
      if (t - fastSince > 3000 && quality < 1) { quality = Math.min(1, quality + 0.1); fastSince = t; }
    } else { slowSince = fastSince = 0; }
    stats.quality = quality;
  }

  function bindTouch(el) {
    if (el._vizTouch) return;
    el._vizTouch = true;
    let lastX = 0, lastY = 0, moved = 0;
    const pos = (e) => { const r = el.getBoundingClientRect(); return [(e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height]; };
    el.addEventListener("pointerdown", (e) => { [lastX, lastY] = pos(e); moved = 0; touch.x = lastX; touch.y = lastY; });
    el.addEventListener("pointermove", (e) => {
      if (!e.buttons && e.pointerType === "mouse") return;
      const [x, y] = pos(e);
      const d = Math.hypot(x - lastX, y - lastY);
      moved += d;
      touch.x = x; touch.y = y;
      touch.swirl = Math.min(1.5, touch.swirl + d * 6);
      lastX = x; lastY = y;
    });
    el.addEventListener("pointerup", (e) => {
      if (moved < 0.02) { const [x, y] = pos(e); touch.tapX = x; touch.tapY = y; touch.tapAt = performance.now() / 1000; }
    });
  }

  const api = {
    MODES, THEMES,
    onModeChange: null,
    attach(el, opts = {}) {
      if (flashEl) flashEl.style.opacity = 0;
      if (canvas !== el) { quality = 1; slowSince = fastSince = 0; stats.intervals.length = 0; }   // each screen starts sharp
      canvas = el;
      flashEl = el.parentElement ? el.parentElement.querySelector(".viz-flash") : null;
      lastFlashOpacity = -1;
      if (!renderers.has(el)) { try { renderers.set(el, makeRenderer(el)); } catch (e) { console.warn("visualizer:", e.message); renderers.set(el, null); } }
      R = renderers.get(el);
      if (opts.touch) bindTouch(el);
      resize();
    },
    start() {
      if (running) return;
      running = true; lastT = 0; lastListen = 0;
      listen();
      listenTimer = setInterval(listen, 16);
      raf = requestAnimationFrame(frame);
    },
    stop() { running = false; cancelAnimationFrame(raf); clearInterval(listenTimer); },
    get running() { return running; },
    get mode() { return MODES[modeIndex]; },
    setMode(i) { modeIndex = ((i % MODES.length) + MODES.length) % MODES.length; store.set("vizMode", modeIndex); return MODES[modeIndex]; },
    next(step = 1) { return this.setMode(modeIndex + step); },
    get auto() { return auto; },
    setAuto(v) { auto = !!v; store.set("vizAuto", auto); },
    get settings() { return settings; },
    set(key, value) { settings[key] = value; store.set("vizSettings", settings); },
    resetSettings() { Object.assign(settings, DEFAULTS); store.set("vizSettings", settings); },
    isLive() { return live; },
    get gpu() { return !!R; },
    get highPrecision() { return !!R && R.highPrecision; },
    setColor(css) {
      const m = String(css).match(/\d+(\.\d+)?/g);
      if (!m || m.length < 3) return;
      const [r, gg, b] = m.map(Number).map((v) => v / 255);
      const mx = Math.max(r, gg, b), mn = Math.min(r, gg, b), d = mx - mn;
      if (!d) return;
      const hh = mx === r ? ((gg - b) / d) % 6 : mx === gg ? (b - r) / d + 2 : (r - gg) / d + 4;
      baseHue = (hh * 60 + 360) % 360;
    },
    get touchSwirl() { return touch.swirl; },
    tap(x, y) { touch.tapX = x; touch.tapY = y; touch.tapAt = performance.now() / 1000; },
    features() { return { bass, mid, high, energy, beat, live, flow, levels: Array.from(levels), shown: Array.from(shown) }; },
    stats,
    resetStats() { stats.frames = 0; stats.drawMs.length = 0; stats.intervals.length = 0; stats.beats = 0; stats.flashes = 0; stats.flashLog.length = 0; stats.modeSwitches = 0; },
  };
  return api;
})();
