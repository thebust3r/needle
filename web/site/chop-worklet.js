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
    this.reset();
  }
  reset() {
    this.envCount = 0; this.fill = 0; this.period = 0; this.anchor = 0; this.confidence = 0; this.samplesSeen = 0;
    this.sinceEstimate = 0; this.level = 0; this.env.fill(0); this.buf.fill(0); this.prevBands.fill(0); this.A.fill(0);
    this.hist.fill(0); this.histSum = 0; this.estimates = 0;
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
  }
  nextBeat(sample) { return this.period <= 0 ? null : this.anchor + Math.ceil((sample - this.anchor) / this.period) * this.period; }
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
  constructor(sampleRate, seed) {
    this.sampleRate = sampleRate;
    this.tracker = new BeatTracker(sampleRate);
    this.cap = Math.floor(sampleRate * 12);     // 12 s of memory: room to hold a loop for a few bars
    this.fade = Math.max(64, Math.floor(sampleRate * 0.006));
    this.rings = [];
    this.rng = (seed || Date.now()) >>> 0 || 1;
    this.history = [];
    this.reset();
  }
  reset() {
    this.tracker.reset();
    this.written = 0; this.beatsSeen = 0; this.lastBeat = -1; this.active = null; this.history = []; this.cooldownUntil = 0; this.holding = false; this.queued = null;
    this.rings.forEach((r) => r.fill(0));
  }
  random() {   // xorshift32
    let x = this.rng; x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0;
    this.rng = x || 1;
    return this.rng / 4294967296;
  }
  process(channels, frames, amount) {
    if (!frames || !channels.length) return;
    while (this.rings.length < channels.length) this.rings.push(new Float32Array(this.cap));
    const start = this.written, cap = this.cap;
    channels.forEach((ch, c) => { const ring = this.rings[c]; let w = start % cap; for (let i = 0; i < frames; i++) { ring[w] = ch[i]; if (++w === cap) w = 0; } });
    this.tracker.feed(channels[0], frames);
    this.written += frames;
    const conf = CHOPS[amount];
    if (conf) this.plan(start, this.written, conf, amount);    // keeps counting beats even during a chop
    const chop = this.active;
    if (!chop) return;
    // holding the loop pad: keep adding one more pass of the same beat just before the current one runs out
    if (chop.loop && this.holding) {
      const p = chop.segs[0].len, last = chop.segs[chop.segs.length - 1];   // the beat length it started with, so every pass is the same beat
      if (chop.start + chop.length - this.written < Math.max(frames * 2, this.fade * 2) && last.delay + p < Math.min(this.cap - 8192, this.written)) {
        chop.segs.push({ at: last.at + last.len, len: p, delay: last.delay + p });
        chop.length += p;
      } else if (last.delay + p >= this.cap - 8192) this.holding = false;
    }
    const f = this.fade, end = chop.start + chop.length;
    if (start >= end + f) {
      this.active = null; this.cooldownUntil = end + this.tracker.period;
      if (this.queued) { const q = this.queued; this.queued = null; this.trigger(q.name, q.hold); }
      return;
    }
    const segs = chop.segs;   // [{at, len, delay}] in samples
    const delayAt = (n) => { for (const g of segs) if (n >= g.at && n < g.at + g.len) return g.delay; return 0; };
    channels.forEach((ch, c) => {
      const ring = this.rings[c];
      const read = (n, d) => (d ? ring[(((n - d) % cap) + cap) % cap] : ch[n - start]);
      for (let i = 0; i < frames; i++) {
        const n = start + i;
        if (n < chop.start || n >= end + f) continue;
        const d = Math.round(delayAt(n));
        // the cut before this sample: fade over 6 ms from what was playing to the new copy
        let k = -1;
        for (let j = 0; j < segs.length; j++) if (n >= segs[j].at && n < segs[j].at + f) k = j;
        const after = n >= end && n < end + f;
        let v = read(n, d);
        if (k >= 0) {
          const prevD = k === 0 ? 0 : Math.round(segs[k - 1].delay);
          const m = (n - segs[k].at) / f;
          v = read(n, prevD) * (1 - m) + v * m;
        } else if (after) {
          const m = (n - end) / f;
          v = read(n, Math.round(segs[segs.length - 1].delay)) * (1 - m) + read(n, 0) * m;
        }
        ch[i] = v;
      }
    });
  }

  /** Live mode: play a move now (or on the beat if it's only a moment away). Every cut goes back whole or half
      beats, so it stays in time wherever you tap. Tapping during a chop lines the move up right after it.
      Returns false if the beat isn't found yet. */
  trigger(name, hold) {
    const t = this.tracker, p = t.period, moves = MOVES[name];
    if (!moves || !(p > 0) || t.confidence <= 0.15) return false;
    const segsFrom = (at) => moves.map(([len, delay]) => { const g = { at, len: len * p, delay: delay * p }; at += len * p; return g; });
    const a = this.active, now = this.written;
    if (a && now < a.start + a.length - this.fade) {
      if (a.length > 8 * p) return false;                       // don't stack up forever
      const segs = segsFrom(a.start + a.length);
      if (Math.max(...segs.map((g) => g.delay)) >= Math.min(this.cap - 8192, this.written)) return false;
      a.segs.push(...segs);
      a.length = segs[segs.length - 1].at + segs[segs.length - 1].len - a.start;
      a.loop = name === "loop"; this.holding = !!hold;
      a.chain = (a.chain || 1) + 1;
      return true;
    }
    if (a) { this.queued = { name, hold }; return true; }         // last few ms of a chop fading out: go right after
    let at = now;
    const b = t.nextBeat(at);
    if (b !== null && b - at < 0.12 * this.sampleRate) at = b;   // snap to a beat that's about to land
    const segs = segsFrom(at);
    if (Math.max(...segs.map((g) => g.delay)) >= Math.min(this.cap - 8192, this.written)) return false;
    this.active = { name, start: at, length: segs[segs.length - 1].at + segs[segs.length - 1].len - at, segs, live: true, loop: name === "loop" };
    this.holding = !!hold;
    this.history.push(this.active);
    if (this.history.length > 64) this.history.shift();
    return true;
  }
  release() { this.holding = false; if (this.queued) this.queued.hold = false; }

  plan(from, to, conf, amount) {
    const t = this.tracker;
    if (t.confidence <= 0.15 || t.period <= 0 || t.samplesSeen <= this.sampleRate * 4) return;
    let beat = t.nextBeat(Math.max(from, this.lastBeat + t.period * 0.5));
    const horizon = to + Math.max(this.fade * 2, Math.min(t.period * 0.5, 8192));
    while (beat !== null && beat < horizon) {
      if (beat > this.lastBeat + t.period * 0.5) {
        this.lastBeat = beat;
        this.beatsSeen++;
        if (!this.active && this.beatsSeen % conf.every === 0 && beat > to && beat >= (this.cooldownUntil || 0) && this.random() < conf.chance) {
          const p = t.period;
          let roll = this.random(), name = PICKS[amount][0][0];
          for (const [n, w] of PICKS[amount]) { if (roll < w) { name = n; break; } roll -= w; }
          let at = beat;
          const segs = MOVES[name].map(([len, delay]) => { const g = { at, len: len * p, delay: delay * p }; at += len * p; return g; });
          const maxDelay = Math.max(...segs.map((g) => g.delay));
          if (maxDelay < this.cap - 8192 && maxDelay < t.samplesSeen) {
            this.active = { name, start: beat, length: at - beat, segs };
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
      this.port.onmessage = (e) => {
        if (e.data.amount) this.amount = e.data.amount;
        if (e.data.reset) this.chopper.reset();
        if (e.data.trigger) this.port.postMessage({ fired: e.data.trigger, ok: this.chopper.trigger(e.data.trigger, e.data.hold) });
        if (e.data.release) this.chopper.release();
      };
    }
    process(inputs, outputs) {
      const input = inputs[0], output = outputs[0];
      if (!input || !input.length) return true;
      for (let c = 0; c < output.length; c++) output[c].set(input[Math.min(c, input.length - 1)]);
      if (this.amount !== "off" || this.chopper.active) this.chopper.process(output, output[0].length, this.amount);
      if (currentFrame - this.lastReport > sampleRate) {   // tell the page what's going on, once a second
        this.lastReport = currentFrame;
        const t = this.chopper.tracker;
        this.port.postMessage({ bpm: t.bpm, confidence: t.confidence, chops: this.chopper.history.length,
                                last: this.chopper.history.length ? this.chopper.history[this.chopper.history.length - 1].name : null });
      }
      return true;
    }
  }
  registerProcessor("needle-chop", ChopProcessor);
}
if (typeof module !== "undefined") module.exports = { BeatTracker, Chopper };
