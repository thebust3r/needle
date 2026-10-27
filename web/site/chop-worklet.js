/* Needle web: chopped & screwed, running on the browser's audio thread (or the page, on plain-http addresses).
   Same beat tracker and chopper as the iPhone app (ios/Needle/Audio/Screw.swift). */
"use strict";

class BeatTracker {
  constructor(sampleRate) {
    // tuned on real songs (see web/tests/beats/README-beats.md): tempo memory ~6 s, gentle preference around 107 BPM,
    // votes from half a beat, 2 beats and 4 beats so it picks the real pulse over in-between tempos
    this.o = { win: 8, ema: 0.96, center: 107, sigma: 0.6, hyst: 1.12, combBeats: 12, conf0: 0.06, conf1: 0.2, h: [0.25, 0.5, 0.25] };
    this.sampleRate = sampleRate;
    this.hop = 512; this.N = 1024;
    this.maxHops = Math.floor(this.o.win * sampleRate / this.hop);
    this.env = new Float32Array(this.maxHops);
    this.buf = new Float32Array(this.N);
    this.re = new Float32Array(this.N); this.im = new Float32Array(this.N);
    this.win = new Float32Array(this.N);
    for (let i = 0; i < this.N; i++) this.win[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / (this.N - 1));
    // bit reversal + twiddles
    this.rev = new Uint16Array(this.N);
    for (let i = 0, bits = Math.log2(this.N); i < this.N; i++) { let r = 0; for (let b = 0; b < bits; b++) r |= ((i >> b) & 1) << (bits - 1 - b); this.rev[i] = r; }
    this.cos = new Float32Array(this.N / 2); this.sin = new Float32Array(this.N / 2);
    for (let i = 0; i < this.N / 2; i++) { this.cos[i] = Math.cos(2 * Math.PI * i / this.N); this.sin[i] = -Math.sin(2 * Math.PI * i / this.N); }
    // 24 bands, log spaced from ~40 Hz to ~11 kHz
    const binHz = sampleRate / this.N, edges = [];
    for (let b = 0; b <= 24; b++) edges.push(Math.max(1, Math.round(40 * Math.pow(11000 / 40, b / 24) / binHz)));
    this.edges = edges;
    this.bands = new Float32Array(24); this.prevBands = new Float32Array(24);
    const hps = sampleRate / this.hop;
    this.minLag = Math.floor(hps * 60 / 190); this.maxLag = Math.ceil(hps * 60 / 50);
    this.A = new Float64Array(4 * this.maxLag + 4);
    this.lin = new Float32Array(this.maxHops);
    this.sc = new Float64Array(this.maxLag + 2);
    this.ph = new Float64Array(this.maxLag + 2);
    this.hist = new Float32Array(16);
    this.log = new Float64Array(512);            // beats already found, in song samples (chops play the past)
    this.reset();
  }
  reset() {
    this.envCount = 0; this.fill = 0; this.period = 0; this.anchor = 0; this.confidence = 0; this.samplesSeen = 0;
    this.sinceEstimate = 0; this.level = 0; this.env.fill(0); this.buf.fill(0); this.prevBands.fill(0); this.A.fill(0);
    this.hist.fill(0); this.histSum = 0; this.estimates = 0;
    this.logCount = 0; this.logEnd = 0;
  }
  get bpm() { return this.period > 0 ? 60 * this.sampleRate / this.period : 0; }
  feed(x, count) {
    for (let i = 0; i < count; i++) {
      const s = x[i];
      this.level = this.level * 0.99998 + s * s * 0.00002;
      this.buf[this.fill++] = s;
      if (this.fill === this.N) { this.frame(); this.buf.copyWithin(0, this.hop); this.fill = this.N - this.hop; }
    }
    this.samplesSeen += count;
  }
  fft() {
    const N = this.N, re = this.re, im = this.im;
    for (let i = 0; i < N; i++) { const r = this.rev[i]; if (r > i) { let t = re[i]; re[i] = re[r]; re[r] = t; t = im[i]; im[i] = im[r]; im[r] = t; } }
    for (let size = 2; size <= N; size <<= 1) {
      const half = size >> 1, step = N / size;
      for (let st = 0; st < N; st += size) for (let j = 0, k = 0; j < half; j++, k += step) {
        const a = st + j, b = a + half, tr = re[b] * this.cos[k] - im[b] * this.sin[k], ti = re[b] * this.sin[k] + im[b] * this.cos[k];
        re[b] = re[a] - tr; im[b] = im[a] - ti; re[a] += tr; im[a] += ti;
      }
    }
  }
  frame() {
    for (let i = 0; i < this.N; i++) { this.re[i] = this.buf[i] * this.win[i]; this.im[i] = 0; }
    this.fft();
    let flux = 0;
    for (let b = 0; b < 24; b++) {
      let s = 0; const a = this.edges[b], e = Math.max(a + 1, this.edges[b + 1]);
      for (let k = a; k < e; k++) s += Math.sqrt(this.re[k] * this.re[k] + this.im[k] * this.im[k]);
      const v = Math.log1p(10 * s / (e - a));
      const d = Math.max(0, v - this.prevBands[b]);
      flux += d;
      this.prevBands[b] = v;
    }
    flux /= 24;
    // take away the slowly-moving part (busy passages vs sparse ones), keep the hits
    const h = this.hist, k = this.envCount % 16;
    this.histSum += flux - h[k]; h[k] = flux;
    const o = Math.max(0, flux - this.histSum / 16);
    this.env[this.envCount % this.maxHops] = o;
    this.envCount++;
    const hps = this.sampleRate / this.hop;
    if (++this.sinceEstimate >= Math.floor(0.25 * hps) && this.envCount >= Math.floor(3 * hps)) { this.sinceEstimate = 0; this.estimate(); }
  }
  e(i) { return i < 0 || i >= this.envCount || this.envCount - i > this.maxHops ? 0 : this.env[i % this.maxHops]; }
  estimate() {
    const o = this.o, n = Math.min(this.envCount, this.maxHops), hps = this.sampleRate / this.hop, start = this.envCount - n;
    let mean = 0; for (let i = start; i < this.envCount; i++) mean += this.e(i); mean /= n;
    // lightly smoothed, so a beat that falls between two analysis steps (e.g. 120 BPM at 48 kHz) still counts fully
    let var0 = 0; const x = this.lin;
    for (let k = 0; k < n; k++) {
      const i = start + k, v = 0.25 * this.e(i - 1) + 0.5 * this.e(i) + 0.25 * this.e(i + 1) - mean;
      x[k] = v; var0 += v * v;
    }
    var0 /= n;
    const loud = this.level > 0.0001;                       // about -40 dB: actual music, not hiss or a fade
    if (var0 < 1e-12 || !loud) {                            // too quiet to learn from: forget, start fresh when it comes in
      this.confidence = 0; this.estimates = 0; this.period = 0; return;
    }
    // average evenly while warming up, then a ~6 s memory
    const A = this.A, ema = Math.min(o.ema, this.estimates / (this.estimates + 1));
    for (let lag = Math.floor(this.minLag / 2); lag <= 4 * this.maxLag + 3; lag++) {
      let s = 0; for (let i = lag; i < n; i++) s += x[i] * x[i - lag];
      const r = lag < n ? s / (n - lag) / var0 : 0;
      A[lag] = A[lag] * ema + r * (1 - ema);
    }
    this.estimates++;
    let best = -1, bestLag = 0;
    const cur = this.period > 0 ? this.period / this.hop : 0;
    const score = (lag) => {
      const h = o.h, at = (l) => Math.max(0, A[Math.floor(l)], A[Math.ceil(l)]);
      let v = (A[lag] + h[0] * at(lag / 2) + h[1] * Math.max(0, A[2 * lag]) + h[2] * Math.max(0, A[4 * lag])) / (1 + h[0] + h[1] + h[2]);
      const oct = Math.log2(60 * hps / lag / o.center);
      v *= Math.exp(-0.5 * oct * oct / (o.sigma * o.sigma));
      if (cur && Math.abs(lag / cur - 1) < 0.04) v *= o.hyst;     // stick with the tempo we have unless something's clearly better
      return v;
    };
    const sc = this.sc;
    for (let lag = this.minLag; lag <= this.maxLag; lag++) { sc[lag] = score(lag); if (sc[lag] > best) { best = sc[lag]; bestLag = lag; } }
    if (bestLag <= this.minLag || bestLag >= this.maxLag) { this.confidence = 0; return; }
    const l = sc[bestLag - 1], r = sc[bestLag + 1], den = l - 2 * best + r;
    let lag = bestLag; if (den < 0) lag += Math.max(-0.5, Math.min(0.5, 0.5 * (l - r) / den));
    const peak = A[bestLag];
    // real music has sharp hits; steady tones, noise and room sound only make small, even ripples
    let hit = 0; for (let i = this.envCount - Math.floor(2 * hps); i < this.envCount; i++) hit = Math.max(hit, this.e(i));
    const hits = Math.max(0, Math.min(1, (hit - 0.4) / 0.12));
    const settled = Math.min(1, this.estimates / 12);          // give it ~3 s of listening before trusting the tempo
    this.confidence = settled * hits * Math.max(0, Math.min(1, (peak - o.conf0) / (o.conf1 - o.conf0)));
    // beats: the offset whose evenly spaced hits are strongest over the last few beats (recent ones count more)
    const steps = Math.max(1, Math.min(Math.floor(lag), this.ph.length)), ph = this.ph;
    let bp = 0, bs = -1;
    for (let off = 0; off < steps; off++) {
      let s = 0;
      for (let k = 0; k < o.combBeats; k++) {
        const idx = this.envCount - 1 - off - Math.round(k * lag), w = 1 - k / (o.combBeats * 1.5);
        s += w * (this.e(idx) + 0.5 * (this.e(idx - 1) + this.e(idx + 1)));
      }
      ph[off] = s; if (s > bs) { bs = s; bp = off; }
    }
    const pl = ph[(bp - 1 + steps) % steps], pr = ph[(bp + 1) % steps], pd = pl - 2 * bs + pr;
    const frac = pd < 0 ? Math.max(-0.5, Math.min(0.5, 0.5 * (pl - pr) / pd)) : 0;
    const newPeriod = lag * this.hop;
    // a flux frame ends at hop end; the hit started about where the frame's newest half begins
    const newAnchor = (this.envCount - 1 - (bp + frac)) * this.hop + this.N - this.hop;
    const sameTempo = this.period > 0 && Math.abs(newPeriod / this.period - 1) < 0.04;
    this.period = sameTempo ? this.period * 0.6 + newPeriod * 0.4 : newPeriod;
    if (sameTempo) {
      // nudge the grid toward the new estimate instead of jumping (unless it's far off)
      let d = (newAnchor - this.anchor) % this.period; if (d > this.period / 2) d -= this.period; if (d < -this.period / 2) d += this.period;
      this.anchor = Math.abs(d) < this.period * 0.15 ? this.anchor + d * 0.5 : newAnchor;
    } else this.anchor = newAnchor;
    // write down the beats that are settled now (a little behind the newest audio)
    if (this.confidence > 0.15) {
      const until = this.samplesSeen - 0.3 * this.sampleRate;
      let b = this.grid(Math.max(this.logEnd, until - 4 * this.sampleRate));
      while (b < until) {
        const last = this.logCount ? this.log[(this.logCount - 1) % 512] : -Infinity;
        if (b - last > this.period * 0.5) { this.log[this.logCount % 512] = b; this.logCount++; }
        b += this.period;
      }
      this.logEnd = until;
    }
  }
  grid(sample) { return this.anchor + Math.ceil((sample - this.anchor) / this.period) * this.period; }
  /** The first beat at or after `sample`: from the beats already found if it's in the past, else from the grid. */
  nextBeat(sample) {
    if (this.period <= 0) return null;
    const n = Math.min(this.logCount, 512);
    if (n && sample <= this.log[(this.logCount - 1) % 512] && sample >= this.log[(this.logCount - n) % 512]) {
      let k = this.logCount - 1;
      while (k > this.logCount - n && this.log[(k - 1) % 512] >= sample) k--;
      return this.log[k % 512];
    }
    return this.grid(sample);
  }
}

// how often a chop can start (in beats) and how likely it is each time; heavy also picks the wilder moves more
// "live" = no automatic chops, you tap them (see trigger)
const CHOPS = { off: null, light: { every: 4, chance: 0.45 }, heavy: { every: 4, chance: 1 }, live: null };

/** The moves, as cuts between the live record and copies that are behind. Each cut: [length, delay] in beats.
    The song's own timeline keeps running underneath, like the second deck. */
const MOVES = {
  repeatBeat: [[1, 1]],                        // hear the last beat again
  runBack: [[2, 2]],                           // run back the last two beats (about a line)
  stutter: [[0.5, 0.5], [0.5, 1], [0.5, 1.5]], // "ch-ch-ch": the same half beat three times
  doubleUp: [[1, 1], [1, 2]],                  // the last beat twice
  backItUp: [[4, 4]],                          // back up a whole bar
  loop: [[1, 1]],                              // live only: the last beat, over and over while held
};
const PICKS = {
  light: [["runBack", 0.45], ["repeatBeat", 0.3], ["stutter", 0.15], ["doubleUp", 0.1]],
  heavy: [["stutter", 0.3], ["runBack", 0.25], ["doubleUp", 0.2], ["repeatBeat", 0.1], ["backItUp", 0.15]],
};

class Chopper {
  /* A playhead over a memory of the song. A chop jumps the playhead back a beat or two (with a 6 ms crossfade into the
     jump, landing right on the beat), and the song then carries on from where the chop ends: every chop adds its
     length to the song, like pausing the record and running it back. `lag` is how far behind the incoming audio
     you are; the player plays that much more before moving to the next song. */
  constructor(sampleRate, seed) {
    this.sampleRate = sampleRate;
    this.tracker = new BeatTracker(sampleRate);
    this.cap = Math.floor(sampleRate * 90);      // 90 s of memory: chops can push the song back up to about a minute
    this.fade = Math.max(64, Math.floor(sampleRate * 0.006));
    this.rings = [];
    this.rng = (seed || Date.now()) >>> 0 || 1;
    this.history = [];
    this.reset();
  }
  reset() {
    this.tracker.reset();
    this.wp = 0; this.rp = 0; this.oc = 0;       // write position, play position (both in song samples), samples played
    this.beatsSeen = 0; this.lastBeat = -1; this.active = null; this.history = []; this.cooldownUntil = 0;
    this.holding = false; this.frozen = false; this.resuming = 0;
    this.rings.forEach((r) => r.fill(0));
  }
  get lag() { return this.wp - this.rp; }
  random() {   // xorshift32
    let x = this.rng; x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0;
    this.rng = x || 1;
    return this.rng / 4294967296;
  }
  /** Paused: hold still (the song isn't coming in, so don't play ahead). Trailing silence from the pause is dropped. */
  pause() {
    if (this.frozen) return;
    this.frozen = true;
    const cap = this.cap, limit = Math.floor(0.25 * this.sampleRate);
    let trimmed = 0;
    while (trimmed < limit && this.wp - 1 > this.rp && this.rings.every((r) => r[(this.wp - 1) % cap] === 0)) { this.wp--; trimmed++; }
  }
  /** Playing again: skip the silence while the song starts back up (up to 1 s), so it doesn't show up later as a gap. */
  play() { if (this.frozen) { this.frozen = false; this.resuming = this.sampleRate; } }

  process(channels, frames, amount) {
    if (!frames || !channels.length) return;
    while (this.rings.length < channels.length) this.rings.push(new Float32Array(this.cap));
    const cap = this.cap;
    if (this.frozen) { for (const ch of channels) ch.fill(0, 0, frames); return; }
    // 1. remember what came in (the record)
    let write = true;
    if (this.resuming > 0) {
      const silent = channels.every((ch) => { for (let i = 0; i < frames; i++) if (ch[i] !== 0) return false; return true; });
      if (silent) { write = false; this.resuming -= frames; } else this.resuming = 0;
    }
    if (write) {
      channels.forEach((ch, c) => { const ring = this.rings[c]; let w = this.wp % cap; for (let i = 0; i < frames; i++) { ring[w] = ch[i]; if (++w === cap) w = 0; } });
      this.tracker.feed(channels[0], frames);
      this.wp += frames;
    }
    // 2. plan the next chop on an upcoming beat
    const conf = CHOPS[amount];
    if (conf && !this.active) this.plan(frames, conf, amount);
    // holding the loop pad: one more pass of the same beat just before the current one runs out
    const A = this.active;
    if (A && A.loop && this.holding && A.next >= A.jumps.length && A.end - this.oc < Math.max(frames * 2, this.fade * 2)) {
      const p0 = A.jumps[0].J;
      if (this.lag + p0 < cap - 8192 - frames) { A.jumps.push({ oc: A.end, J: p0 }); A.end += p0; } else this.holding = false;
    }
    // 3. play from the playhead
    const f = this.fade, nch = channels.length;
    for (let i = 0; i < frames; i++) {
      if (this.rp >= this.wp) { for (let c = 0; c < nch; c++) channels[c][i] = 0; continue; }   // waiting for the song to come back in
      let J = 0, m = 0;
      const a = this.active;
      if (a && a.next < a.jumps.length) {
        const j = a.jumps[a.next];
        if (this.oc >= j.oc) {                           // the jump: land on the beat
          const at = this.rp;
          this.rp -= Math.round(j.J);
          (a.played || (a.played = [])).push({ oc: this.oc, at, from: this.rp, len: (a.next + 1 < a.jumps.length ? a.jumps[a.next + 1].oc : a.end) - this.oc });
          a.next++;
        } else if (this.oc >= j.oc - f) { J = Math.round(j.J); m = (this.oc - (j.oc - f)) / f; }   // fading into it
      }
      const r0 = this.rp % cap, r1 = (this.rp - J) % cap;
      for (let c = 0; c < nch; c++) { const ring = this.rings[c]; channels[c][i] = J ? ring[r0] * (1 - m) + ring[r1] * m : ring[r0]; }
      this.rp++; this.oc++;
    }
    if (A && A.next >= A.jumps.length && this.oc >= A.end && !(A.loop && this.holding)) {
      this.active = null;
      this.cooldownUntil = this.oc + this.tracker.period;
      this.changed = true;                               // lag changed: tell the page
    }
  }

  /** Moves as jumps for the playhead: [[length, delay], ...] in beats -> [{oc, J}] in samples, starting at `at`. */
  jumpsFor(name, at, p) {
    let prev = 0; const out = [];
    for (const [len, delay] of MOVES[name]) { out.push({ oc: at, J: (delay - prev) * p }); prev = delay; at += len * p; }
    return { jumps: out, end: at };
  }
  fits(extra) { return this.lag + extra < this.cap - 8192 - 4096 && extra <= this.rp; }

  /** Live mode: play a move now (or on the beat if it's only a moment away). Tapping during a chop lines the move
      up right after it. Returns false if the beat isn't found yet. */
  trigger(name, hold) {
    const t = this.tracker, p = t.period;
    if (!MOVES[name] || !(p > 0) || t.confidence <= 0.15) return false;
    const a = this.active, f = this.fade;
    if (a) {
      if (a.jumps.length > 24) return false;                  // don't stack up forever
      const start = Math.max(a.end, this.oc + f);
      const { jumps, end } = this.jumpsFor(name, start, p);
      const extra = jumps.reduce((s, j) => s + j.J, 0) + (a.end - this.oc);
      if (!this.fits(extra)) return false;
      a.jumps.push(...jumps); a.end = end; a.loop = name === "loop"; this.holding = !!hold;
      a.chain = (a.chain || 1) + 1;
      return true;
    }
    // land on a beat that's about to come (in the song as you hear it), else right away
    let start = this.oc + f;
    const pos = this.rp + f, nb = t.nextBeat(pos);
    if (nb !== null && nb - pos < 0.12 * this.sampleRate) start = this.oc + Math.round(nb - this.rp);
    const { jumps, end } = this.jumpsFor(name, start, p);
    if (!this.fits(jumps.reduce((s, j) => s + j.J, 0))) return false;
    this.active = { name, start, jumps, end, next: 0, live: true, loop: name === "loop" };
    this.holding = !!hold;
    this.history.push(this.active);
    if (this.history.length > 64) this.history.shift();
    return true;
  }
  release() { this.holding = false; }

  plan(frames, conf, amount) {
    const t = this.tracker;
    if (t.confidence <= 0.15 || t.period <= 0 || t.samplesSeen <= this.sampleRate * 4) return;
    // beats in the song as you hear it (the playhead), counted as they go by
    const horizon = this.rp + frames + Math.max(this.fade * 2, Math.min(t.period * 0.5, 8192));
    let beat = t.nextBeat(Math.max(this.rp, this.lastBeat + t.period * 0.5));
    while (beat !== null && beat < horizon) {
      if (beat > this.lastBeat + t.period * 0.5) {
        this.lastBeat = beat;
        this.beatsSeen++;
        const start = this.oc + Math.round(beat - this.rp);
        if (this.beatsSeen % conf.every === 0 && beat - this.rp > this.fade && start >= this.cooldownUntil && this.random() < conf.chance) {
          let roll = this.random(), name = PICKS[amount][0][0];
          for (const [n, w] of PICKS[amount]) { if (roll < w) { name = n; break; } roll -= w; }
          const { jumps, end } = this.jumpsFor(name, start, t.period);
          if (this.fits(jumps.reduce((s, j) => s + j.J, 0))) {
            this.active = { name, start, jumps, end, next: 0 };
            this.history.push(this.active);
            if (this.history.length > 64) this.history.shift();
            return;
          }
        }
      }
      beat += t.period;
    }
  }
}

if (typeof registerProcessor === "function") {
  class ChopProcessor extends AudioWorkletProcessor {
    constructor() {
      super();
      this.amount = "off";
      this.chopper = new Chopper(sampleRate);
      this.lastReport = 0;
      this.silence = [new Float32Array(128), new Float32Array(128)];
      this.port.onmessage = (e) => handleChopMessage(this.chopper, e.data, (m) => this.port.postMessage(m), (a) => { this.amount = a; });
    }
    process(inputs, outputs) {
      const input = inputs[0] && inputs[0].length ? inputs[0] : this.silence, output = outputs[0];
      for (let c = 0; c < output.length; c++) output[c].set(input[Math.min(c, input.length - 1)]);
      const c = this.chopper;
      if (this.amount !== "off" || c.active || c.lag > 0 || c.frozen) c.process(output, output[0].length, this.amount);
      if (c.changed || currentFrame - this.lastReport > sampleRate) {   // tell the page what's going on, once a second
        c.changed = false;
        this.lastReport = currentFrame;
        this.port.postMessage(chopStats(c));
      }
      return true;
    }
  }
  registerProcessor("needle-chop", ChopProcessor);
}
function chopStats(c) {
  const t = c.tracker, h = c.history;
  return { bpm: t.bpm, confidence: t.confidence, chops: h.length, last: h.length ? h[h.length - 1].name : null, lag: c.lag / c.sampleRate };
}
/** Messages from the page (same for the audio thread and the page fallback). */
function handleChopMessage(c, d, reply, setAmount) {
  if (d.amount) setAmount(d.amount);
  if (d.reset) { c.reset(); reply(chopStats(c)); }
  if (d.pause === true) c.pause();
  if (d.pause === false) c.play();
  if (d.trigger) reply({ fired: d.trigger, ok: c.trigger(d.trigger, d.hold) });
  if (d.release) c.release();
}
if (typeof module !== "undefined") module.exports = { BeatTracker, Chopper, chopStats, handleChopMessage };
