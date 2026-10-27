/* Needle web: chopped & screwed, running on the browser's audio thread.
   Same beat tracker and chopper as the iPhone app (ios/Needle/Audio/Screw.swift). */
"use strict";

class BeatTracker {
  constructor(sampleRate) {
    this.sampleRate = sampleRate;
    this.hop = 512;
    this.maxHops = Math.floor(6 * sampleRate / this.hop);
    this.env = new Float32Array(this.maxHops);
    this.envLow = new Float32Array(this.maxHops);
    this.reset();
  }
  reset() {
    this.envCount = 0; this.acc = 0; this.accLow = 0; this.accAll = 0; this.lp = 0; this.prevLow = 0; this.prevAll = 0;
    this.period = 0; this.anchor = 0; this.confidence = 0; this.samplesSeen = 0; this.sinceEstimate = 0; this.level = 0;
    this.env.fill(0); this.envLow.fill(0);
  }
  get bpm() { return this.period > 0 ? 60 * this.sampleRate / this.period : 0; }
  feed(x, count) {
    const a = 1 - Math.exp(-2 * Math.PI * 180 / this.sampleRate);
    for (let i = 0; i < count; i++) {
      const s = x[i];
      this.lp += a * (s - this.lp);
      this.accLow += this.lp * this.lp;
      this.accAll += s * s;
      this.level = this.level * 0.99998 + s * s * 0.00002;     // slow running loudness (~1 s)
      if (++this.acc === this.hop) this.pushHop();
    }
    this.samplesSeen += count;
  }
  pushHop() {
    const low = Math.log1p(this.accLow * 40), all = Math.log1p(this.accAll * 10);
    const onset = Math.max(0, low - this.prevLow) + 0.5 * Math.max(0, all - this.prevAll);
    this.prevLow = low; this.prevAll = all;
    this.accLow = 0; this.accAll = 0; this.acc = 0;
    this.env[this.envCount % this.maxHops] = onset;
    this.envLow[this.envCount % this.maxHops] = Math.max(0, low - this.prevLowForPhase || 0);
    this.prevLowForPhase = low;
    this.envCount++;
    this.sinceEstimate++;
    const hps = this.sampleRate / this.hop;
    if (this.sinceEstimate >= Math.floor(0.5 * hps) && this.envCount >= Math.floor(3 * hps)) { this.sinceEstimate = 0; this.estimate(); }
  }
  e(i) {
    if (i < 0 || i >= this.envCount || this.envCount - i > this.maxHops) return 0;
    return this.env[i % this.maxHops];
  }
  eLow(i) {
    if (i < 0 || i >= this.envCount || this.envCount - i > this.maxHops) return 0;
    return this.envLow[i % this.maxHops];
  }
  estimate() {
    const n = Math.min(this.envCount, this.maxHops), hps = this.sampleRate / this.hop;
    const minLag = Math.floor(hps * 60 / 180), maxLag = Math.floor(hps * 60 / 55) + 1;
    const start = this.envCount - n;
    let mean = 0;
    for (let i = start; i < this.envCount; i++) mean += this.e(i);
    mean /= n;
    let var0 = 0;
    for (let i = start; i < this.envCount; i++) var0 += (this.e(i) - mean) ** 2;
    var0 /= n;
    let best = 0, bestLag = 0, total = 0;
    const scores = new Float64Array(maxLag + 2);
    for (let lag = minLag; lag <= maxLag; lag++) {
      let s = 0;
      for (let i = start + lag; i < this.envCount; i++) s += (this.e(i) - mean) * (this.e(i - lag) - mean);
      let v = s / (n - lag);
      const oct = Math.log2((60 * hps / lag) / 100);
      v *= Math.exp(-0.5 * (oct * oct) / 0.36);
      scores[lag] = v;
      if (v > 0) total += v;
      if (v > best) { best = v; bestLag = lag; }
    }
    if (!bestLag || best <= 0) { this.confidence = 0; return; }
    let lag = bestLag;
    const l = scores[Math.max(minLag, bestLag - 1)], r = scores[Math.min(maxLag, bestLag + 1)], den = l - 2 * best + r;
    if (den < 0) lag += 0.5 * (l - r) / den;
    const newPeriod = lag * this.hop;
    const prior = Math.exp(-0.5 * (Math.log2((60 * hps / bestLag) / 100) ** 2) / 0.36);
    const strength = var0 > 1e-9 ? best / prior / var0 : 0;                // 0 = no repeating pattern, 1 = perfect
    const recent = (() => { let a = 0; for (let i = this.envCount - Math.floor(2 * hps); i < this.envCount; i++) a += this.e(i); return a; })();
    const loudEnough = this.level > 0.0003;                                 // about -35 dB: actual music, not hiss
    this.confidence = recent < 0.5 || !loudEnough ? 0 : Math.max(0, Math.min(1, (strength - 0.12) / 0.3));
    let bestPhase = 0, bestScore = -1;
    const phase = new Float64Array(Math.max(1, Math.floor(lag)));
    for (let o = 0; o < Math.max(1, Math.floor(lag)); o++) {
      let sc = 0;
      for (let k = 0; k < 8; k++) {
        const idx = this.envCount - 1 - o - Math.round(k * lag);
        sc += this.eLow(idx) + 0.5 * (this.eLow(idx - 1) + this.eLow(idx + 1)) + 0.3 * this.e(idx);
      }
      phase[o] = sc;
      if (sc > bestScore) { bestScore = sc; bestPhase = o; }
    }
    // sub-step accuracy from the neighbors
    const steps = Math.max(1, Math.floor(lag));
    const pl = phase[(bestPhase - 1 + steps) % steps], pr = phase[(bestPhase + 1) % steps], pd = pl - 2 * bestScore + pr;
    let frac = pd < 0 ? 0.5 * (pl - pr) / pd : 0;
    frac = Math.max(-0.5, Math.min(0.5, frac));
    const newAnchor = (this.envCount - 1 - (bestPhase + frac) + 0.5) * this.hop;
    this.period = this.period > 0 && Math.abs(newPeriod - this.period) / this.period < 0.04 ? this.period * 0.7 + newPeriod * 0.3 : newPeriod;
    this.anchor = newAnchor;
  }
  nextBeat(sample) {
    if (this.period <= 0) return null;
    return this.anchor + Math.ceil((sample - this.anchor) / this.period) * this.period;
  }
}

const CHOPS = { off: null, light: { every: 16, chance: 0.6 }, heavy: { every: 8, chance: 0.85 } };

class Chopper {
  constructor(sampleRate, seed) {
    this.sampleRate = sampleRate;
    this.tracker = new BeatTracker(sampleRate);
    this.cap = Math.floor(sampleRate * 5);
    this.fade = Math.max(64, Math.floor(sampleRate * 0.006));
    this.rings = [];
    this.rng = (seed || Date.now()) >>> 0 || 1;
    this.history = [];
    this.reset();
  }
  reset() {
    this.tracker.reset();
    this.written = 0; this.beatsSeen = 0; this.lastBeat = -1; this.active = null; this.history = [];
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
    if (!this.active && conf) this.plan(start, this.written, conf, amount);
    const chop = this.active;
    if (!chop) return;
    const d = Math.round(chop.delay), s0 = Math.round(chop.start), s1 = Math.round(chop.start + chop.length), f = this.fade;
    if (start >= chop.start + chop.length + f) { this.active = null; return; }
    channels.forEach((ch, c) => {
      const ring = this.rings[c];
      for (let i = 0; i < frames; i++) {
        const n = start + i;
        if (n < s0 - f || n >= s1 + f) continue;
        const m = n < s0 ? (n - (s0 - f)) / f : n < s1 ? 1 : 1 - (n - s1) / f;
        const late = ring[(((n - d) % cap) + cap) % cap];
        ch[i] = ch[i] * (1 - m) + late * m;
      }
    });
  }
  plan(from, to, conf, amount) {
    const t = this.tracker;
    if (t.confidence <= 0.25 || t.period <= 0 || t.samplesSeen <= this.sampleRate * 4) return;
    let beat = t.nextBeat(Math.max(from, this.lastBeat + t.period * 0.5));
    const horizon = to + Math.max(this.fade * 2, Math.min(t.period * 0.5, 8192));
    while (beat !== null && beat < horizon) {
      if (beat > this.lastBeat + t.period * 0.5) {
        this.lastBeat = beat;
        this.beatsSeen++;
        if (this.beatsSeen % conf.every === 0 && beat - this.fade > to && this.random() < conf.chance) {
          const p = t.period, roll = this.random();
          const chop = amount === "heavy" && roll < 0.3 ? { start: beat, length: p, delay: p / 2 }
            : roll < 0.75 ? { start: beat, length: p, delay: p } : { start: beat, length: 2 * p, delay: 2 * p };
          if (chop.delay < this.cap - 4096) {
            this.active = chop;
            this.history.push(chop);
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
        this.port.postMessage({ bpm: t.bpm, confidence: t.confidence, chops: this.chopper.history.length });
      }
      return true;
    }
  }
  registerProcessor("needle-chop", ChopProcessor);
}
if (typeof module !== "undefined") module.exports = { BeatTracker, Chopper };
