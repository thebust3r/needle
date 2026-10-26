/* Needle visualizer — an original, Neon-spirited light show driven by the music.
   Four modes, beat detection, album colors, and safety limits:
   - flashes are capped at 3 per second and kept soft (WCAG 2.3.1)
   - "Reduce Motion" slows everything down and turns flashes off
   - quality drops automatically if the phone can't keep up */
"use strict";

const Viz = (() => {
  const MODES = [
    { id: "tunnel", name: "Warp Ring" },
    { id: "prism", name: "Prism" },
    { id: "hyper", name: "Hyperspace" },
    { id: "melt", name: "Melt" },
  ];
  const BINS = 48;
  const reducedMQ = window.matchMedia ? matchMedia("(prefers-reduced-motion: reduce)") : { matches: false };

  let canvas = null, g = null, flashEl = null, lastFlashOpacity = -1;
  const scratch = document.createElement("canvas");
  const sg = scratch.getContext("2d");
  let raf = 0, running = false, lastT = 0, w = 0, h = 0;
  let quality = 1;                       // resolution factor, adapts to the device
  let modeIndex = clamp(+store.get("vizMode", 0) || 0, 0, MODES.length - 1);
  let auto = store.get("vizAuto", true);

  // audio features
  const levels = new Float32Array(BINS);
  let freq = null, wave = null, live = false;
  let bass = 0, mid = 0, high = 0, energy = 0;
  let bassAvg = 0, longAvg = 0, lastBeat = 0, beat = 0, quietSince = 0, lastSwitch = 0;
  const flashTimes = [];
  let flash = 0;

  // neon color strings, cached so drawing doesn't allocate
  const neon = [], neonDim = [];
  for (let d = 0; d < 360; d++) { neon.push(`hsl(${d},95%,62%)`); neonDim.push(`hsla(${d},95%,62%,0.55)`); }
  let baseHue = 175;
  const hueAt = (offset) => ((Math.round(baseHue + offset) % 360) + 360) % 360;

  const stars = [];
  for (let i = 0; i < 260; i++) stars.push(newStar(Math.random()));
  function newStar(z) { return { x: (Math.random() * 2 - 1), y: (Math.random() * 2 - 1), z: z ?? 1, hue: Math.random() * 120 }; }

  // numbers for tests and the quality governor
  const stats = { frames: 0, drawMs: [], intervals: [], beats: 0, flashes: 0, flashLog: [], modeSwitches: 0, quality: 1, resizes: 0 };
  let slowSince = 0, fastSince = 0;

  function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }
  const reduced = () => reducedMQ.matches;

  /* ---------- sizing ---------- */
  function resize() {
    if (!canvas) return;
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const cw = canvas.clientWidth || 300, ch = canvas.clientHeight || 300;
    const nw = Math.max(64, Math.round(Math.min(cw * dpr, 1400) * quality));
    const nh = Math.max(64, Math.round(Math.min(ch * dpr, 1400 * (ch / cw)) * quality));
    if (nw === w && nh === h) return;
    w = canvas.width = scratch.width = nw;
    h = canvas.height = scratch.height = nh;
    g.fillStyle = "#000";
    g.fillRect(0, 0, w, h);
    stats.resizes++;
  }

  /* ---------- listening ---------- */
  function readAudio(t, k) {
    const a = audio.vizAnalyser;
    live = !!(a && player.playing && player.el && player.el.routed && audio.ctx && audio.ctx.state === "running");
    if (live) {
      if (!freq || freq.length !== a.frequencyBinCount) {
        freq = new Float32Array(a.frequencyBinCount);
        wave = new Float32Array(a.fftSize);
      }
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
    } else {
      // gentle idle motion so it never looks dead
      for (let b = 0; b < BINS; b++) levels[b] = 0.1 + 0.07 * Math.sin(t * 0.0011 + b * 0.35) * Math.sin(t * 0.0007 + b * 0.13);
    }
    let s = 0;
    for (let b = 0; b < 6; b++) s += levels[b];
    bass = s / 6;
    s = 0; for (let b = 6; b < 25; b++) s += levels[b]; mid = s / 19;
    s = 0; for (let b = 25; b < BINS; b++) s += levels[b]; high = s / (BINS - 25);
    energy = (bass * 2 + mid + high) / 4;

    // beat = bass jumping clearly above its recent average
    bassAvg = bassAvg * 0.9 + bass * 0.1;
    longAvg = longAvg * 0.995 + bass * 0.005;
    if (live && bass > bassAvg * 1.12 + 0.035 && bass > 0.28 && t - lastBeat > 240) {
      lastBeat = t;
      beat = 1;
      stats.beats++;
      onBeat(t);
    }
    beat *= Math.pow(reduced() ? 0.82 : 0.9, k);
    flash *= Math.pow(0.8, k);

    // a "drop": quiet for a while, then the bass slams back in
    if (live && bass < longAvg * 0.6) { if (!quietSince) quietSince = t; }
    else if (quietSince) {
      if (auto && t - quietSince > 1500 && bass > longAvg * 1.3) switchMode(t);
      quietSince = 0;
    }
  }

  function onBeat(t) {
    // flash safety: at most 3 soft flashes per second, none with Reduce Motion
    while (flashTimes.length && t - flashTimes[0] > 1000) flashTimes.shift();
    if (!reduced() && flashTimes.length < 3 && energy > 0.35) {
      flashTimes.push(t);
      flash = 1;
      stats.flashes++;
      stats.flashLog.push(t); if (stats.flashLog.length > 100) stats.flashLog.shift();
    }
    if (auto && t - lastSwitch > 45000) switchMode(t);   // keep things fresh on long songs
  }

  function switchMode(t) {
    modeIndex = (modeIndex + 1) % MODES.length;
    lastSwitch = t;
    stats.modeSwitches++;
    if (api.onModeChange) api.onModeChange(MODES[modeIndex]);
  }

  /* ---------- drawing ---------- */
  function feedback(zoom, rot, decay, dx = 0, dy = 0) {
    sg.globalCompositeOperation = "copy";
    sg.drawImage(canvas, 0, 0);
    g.globalCompositeOperation = "source-over";
    g.globalAlpha = 1;
    g.fillStyle = "#000";
    g.fillRect(0, 0, w, h);
    g.save();
    g.translate(w / 2 + dx, h / 2 + dy);
    g.rotate(rot);
    g.scale(zoom, zoom);
    g.translate(-w / 2, -h / 2);
    g.globalAlpha = decay;
    g.drawImage(scratch, 0, 0);
    g.restore();
    g.globalAlpha = 1;
  }

  function sample(i, count) {           // waveform value -1..1 at position i of count
    if (!live || !wave) return Math.sin(i / count * Math.PI * 4 + performance.now() * 0.002) * 0.15;
    return wave[Math.floor(i / count * (wave.length - 1))];
  }

  function drawTunnel(t, k, m) {
    const slow = reduced() ? 0.35 : 1;
    feedback(1 + (0.022 + bass * 0.06 + beat * 0.035) * slow, (0.003 + mid * 0.012) * k * slow, 0.84);
    g.globalCompositeOperation = "lighter";
    const r0 = m * (0.1 + bass * 0.07 + beat * 0.05);
    const len = m * 0.27;
    g.lineWidth = Math.max(1.5, m * 0.009);
    g.lineCap = "round";
    const spin = t * 0.0004 * slow;
    for (let side = 0; side < 2; side++) {
      for (let b = 0; b < BINS; b++) {
        const a = spin + (side ? -1 : 1) * (b / BINS) * Math.PI;
        const ca = Math.cos(a), sa = Math.sin(a), l = r0 + levels[b] * len;
        g.strokeStyle = neonDim[hueAt(b * 2.5 + side * 40)];
        g.beginPath();
        g.moveTo(w / 2 + ca * r0, h / 2 + sa * r0);
        g.lineTo(w / 2 + ca * l, h / 2 + sa * l);
        g.stroke();
      }
    }
    if (beat > 0.05) {
      g.strokeStyle = neonDim[hueAt(180)];
      g.globalAlpha = beat;
      g.lineWidth = m * 0.012;
      g.beginPath(); g.arc(w / 2, h / 2, r0 * (1.3 + (1 - beat) * 1.6), 0, Math.PI * 2); g.stroke();
      g.globalAlpha = 1;
    }
  }

  function drawPrism(t, k, m) {
    const slow = reduced() ? 0.35 : 1;
    feedback(0.982 - beat * 0.02 * slow, -(0.005 + high * 0.02) * k * slow, 0.82);
    g.globalCompositeOperation = "lighter";
    const R = m * 0.48, pts = 48, amp = R * (0.18 + energy * 0.5);
    g.lineWidth = Math.max(1.5, m * 0.007);
    g.lineJoin = "round";
    const turn = t * 0.00025 * slow;
    for (let s = 0; s < 6; s++) {
      for (let mirror = 0; mirror < 2; mirror++) {
        g.save();
        g.translate(w / 2, h / 2);
        g.rotate(turn + s * Math.PI / 3);
        if (mirror) g.scale(1, -1);
        g.strokeStyle = neon[hueAt(s * 60 + mirror * 25)];
        g.beginPath();
        for (let i = 0; i <= pts; i++) {
          const x = (i / pts) * R, y = sample(i, pts) * amp * (i / pts);
          i ? g.lineTo(x, y) : g.moveTo(x, y);
        }
        g.stroke();
        const r = m * (0.006 + high * 0.03 + beat * 0.012);
        g.fillStyle = neon[hueAt(s * 60 + 180)];
        g.beginPath(); g.arc(R * 0.62, sample(30, pts) * amp * 0.62, r, 0, Math.PI * 2); g.fill();
        g.restore();
      }
    }
  }

  function drawHyper(t, k, m) {
    const slow = reduced() ? 0.4 : 1;
    feedback(1.0, 0.0012 * k * slow, 0.74);
    g.globalCompositeOperation = "lighter";
    const speed = (0.004 + bass * 0.028 + beat * 0.02) * k * slow;
    const cx = w / 2, cy = h / 2, f = m * 0.5;
    g.lineCap = "round";
    for (let i = 0; i < stars.length; i++) {
      const st = stars[i];
      const z0 = st.z;
      st.z -= speed;
      if (st.z <= 0.03) { stars[i] = newStar(1); continue; }
      const x0 = cx + st.x / z0 * f * 0.35, y0 = cy + st.y / z0 * f * 0.35;
      const x1 = cx + st.x / st.z * f * 0.35, y1 = cy + st.y / st.z * f * 0.35;
      if (x1 < -20 || x1 > w + 20 || y1 < -20 || y1 > h + 20) { stars[i] = newStar(1); continue; }
      g.strokeStyle = neon[hueAt(st.hue + high * 90)];
      g.lineWidth = Math.max(1, (1 - st.z) * m * 0.009);
      g.beginPath(); g.moveTo(x0, y0); g.lineTo(x1, y1); g.stroke();
    }
    g.fillStyle = neonDim[hueAt(0)];
    g.globalAlpha = 0.25 + bass * 0.5;
    g.beginPath(); g.arc(cx, cy, m * (0.02 + bass * 0.05 + beat * 0.03), 0, Math.PI * 2); g.fill();
    g.globalAlpha = 1;
  }

  function drawMelt(t, k, m) {
    const slow = reduced() ? 0.35 : 1;
    feedback(1 + (0.01 + bass * 0.02) * slow, Math.sin(t * 0.0005) * 0.004 * slow, 0.88, 0, -1.4 * k * slow * (h / 600));
    g.globalCompositeOperation = "lighter";
    const pts = 64;
    g.lineJoin = "round";
    for (let line = 0; line < 3; line++) {
      const yBase = h * (0.38 + line * 0.13), amp = h * (0.08 + mid * 0.22 + beat * 0.05);
      g.strokeStyle = neon[hueAt(line * 110 + t * 0.01)];
      g.lineWidth = Math.max(1.5, m * (0.006 + line * 0.002));
      g.beginPath();
      for (let i = 0; i <= pts; i++) {
        const x = (i / pts) * w, y = yBase + sample((i + line * 9) % (pts + 1), pts) * amp;
        i ? g.lineTo(x, y) : g.moveTo(x, y);
      }
      g.stroke();
    }
  }

  const DRAW = { tunnel: drawTunnel, prism: drawPrism, hyper: drawHyper, melt: drawMelt };

  function frame(t) {
    if (!running) return;
    raf = requestAnimationFrame(frame);
    if (document.hidden || !canvas || !canvas.isConnected) return;
    const dt = lastT ? Math.min(60, t - lastT) : 16.7;
    lastT = t;
    const t0 = performance.now();
    resize();
    const k = dt / 16.67;
    readAudio(t, k);
    baseHue += (reduced() ? 0.05 : 0.15) * k;
    const m = Math.min(w, h);
    DRAW[MODES[modeIndex].id](t, k, m);
    g.globalCompositeOperation = "source-over";
    // soft beat flash on a separate layer above the canvas, so it never gets baked into the trails
    if (flashEl) {
      const o = flash > 0.02 ? +(flash * 0.18).toFixed(3) : 0;
      if (o !== lastFlashOpacity) {
        flashEl.style.opacity = o;
        if (o && !lastFlashOpacity) flashEl.style.background = neon[hueAt(200)];
        lastFlashOpacity = o;
      }
    }
    governor(t, performance.now() - t0, dt);
  }

  /** Keeps it smooth: lowers resolution if frames get slow, raises it again when there's headroom. */
  function governor(t, ms, dt) {
    stats.frames++;
    stats.drawMs.push(ms); if (stats.drawMs.length > 240) stats.drawMs.shift();
    stats.intervals.push(dt); if (stats.intervals.length > 240) stats.intervals.shift();
    const recent = stats.intervals.slice(-30);
    const avgDt = recent.reduce((a, b) => a + b, 0) / recent.length;
    const avgMs = stats.drawMs.slice(-30).reduce((a, b) => a + b, 0) / Math.min(30, stats.drawMs.length);
    if (avgDt > 20 || avgMs > 8) {          // under ~50 fps: lower the resolution a notch
      fastSince = 0;
      if (!slowSince) slowSince = t;
      if (t - slowSince > 800 && quality > 0.4) { quality = Math.max(0.4, quality - 0.15); slowSince = t; resize(); }
    } else if (avgDt < 17.5 && avgMs < 4) {
      slowSince = 0;
      if (!fastSince) fastSince = t;
      if (t - fastSince > 4000 && quality < 1) { quality = Math.min(1, quality + 0.15); fastSince = t; resize(); }
    } else { slowSince = fastSince = 0; }
    stats.quality = quality;
  }

  const api = {
    MODES,
    onModeChange: null,
    attach(el) {
      if (flashEl) flashEl.style.opacity = 0;
      canvas = el;
      flashEl = el.parentElement ? el.parentElement.querySelector(".viz-flash") : null;
      lastFlashOpacity = -1;
      g = el.getContext("2d", { alpha: false });
      w = h = 0;
      resize();
    },
    start() { if (running) return; running = true; lastT = 0; raf = requestAnimationFrame(frame); },
    stop() { running = false; cancelAnimationFrame(raf); },
    get running() { return running; },
    get mode() { return MODES[modeIndex]; },
    setMode(i) { modeIndex = ((i % MODES.length) + MODES.length) % MODES.length; store.set("vizMode", modeIndex); return MODES[modeIndex]; },
    next(step = 1) { return this.setMode(modeIndex + step); },
    get auto() { return auto; },
    setAuto(v) { auto = !!v; store.set("vizAuto", auto); },
    isLive() { return live; },
    setColor(css) {
      const m = String(css).match(/\d+(\.\d+)?/g);
      if (!m || m.length < 3) return;
      const [r, gg, b] = m.map(Number).map((v) => v / 255);
      const mx = Math.max(r, gg, b), mn = Math.min(r, gg, b), d = mx - mn;
      if (!d) return;
      let hh = mx === r ? ((gg - b) / d) % 6 : mx === gg ? (b - r) / d + 2 : (r - gg) / d + 4;
      baseHue = (hh * 60 + 360) % 360;
    },
    features() { return { bass, mid, high, energy, beat, live, levels: Array.from(levels) }; },
    stats,
    resetStats() { stats.frames = 0; stats.drawMs.length = 0; stats.intervals.length = 0; stats.beats = 0; stats.flashes = 0; stats.flashLog.length = 0; stats.modeSwitches = 0; },
  };
  return api;
})();
