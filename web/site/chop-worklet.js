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
    this.lp2 = 0; this.accHigh = 0; this.prevHigh = 0; this.lowHist = [0, 0, 0];
    this.period = 0; this.anchor = 0; this.confidence = 0; this.samplesSeen = 0; this.sinceEstimate = 0; this.level = 0;
    this.env.fill(0); this.envLow.fill(0);
  }
  get bpm() { return this.period > 0 ? 60 * this.sampleRate / this.period : 0; }
  feed(x, count) {
    const a = 1 - Math.exp(-2 * Math.PI * 180 / this.sampleRate), a2 = 1 - Math.exp(-2 * Math.PI * 2500 / this.sampleRate);
    for (let i = 0; i < count; i++) {
      const s = x[i];
      this.lp += a * (s - this.lp);
      this.lp2 += a2 * (s - this.lp2);
      const h = s - this.lp2;
      this.accHigh += h * h;
      this.accLow += this.lp * this.lp;
      this.accAll += s * s;
      this.level = this.level * 0.99998 + s * s * 0.00002;     // slow running loudness (~1 s)
      if (++this.acc === this.hop) this.pushHop();
    }
    this.samplesSeen += count;
  }
  pushHop() {
    // Low band is averaged over ~35 ms for the tempo, so long sliding 808s (whose energy ripples hop to hop) don't
    // drown the pattern. Hats and snares (high band) also count, for songs where the bass never really "hits".
    const lh = this.lowHist; lh.shift(); lh.push(this.accLow);
    const lowRaw = Math.log1p(this.accLow * 40), low = Math.log1p((lh[0] + lh[1] + lh[2]) / 3 * 40);
    const all = Math.log1p(this.accAll * 10), high = Math.log1p(this.accHigh * 200);
    const onset = Math.max(0, low - this.prevLow) + 0.5 * Math.max(0, all - this.prevAll) + 0.7 * Math.max(0, high - this.prevHigh);
    this.prevLow = low; this.prevAll = all; this.prevHigh = high;
    this.accLow = 0; this.accAll = 0; this.accHigh = 0; this.acc = 0;
    this.env[this.envCount % this.maxHops] = onset;
    this.envLow[this.envCount % this.maxHops] = Math.max(0, lowRaw - this.prevLowForPhase || 0);
    this.prevLowForPhase = lowRaw;
    this.envCount++;
    this.sinceEstimate++;
    const hps = this.sampleRate / this.hop;
    if (this.sinceEstimate >= Math.floor(0.25 * hps) && this.envCount >= Math.floor(3 * hps)) { this.sinceEstimate = 0; this.estimate(); }
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
    // Autocorrelation, plus a half-weight vote from twice the lag: a beat that also lines up two beats later (where
    // kicks and 808s usually repeat) wins over an in-between lag that only the steady hi-hats agree with.
    const raw = new Float64Array(2 * maxLag + 2);
    for (let lag = minLag; lag <= 2 * maxLag + 1 && lag < n; lag++) {
      let s = 0;
      for (let i = start + lag; i < this.envCount; i++) s += (this.e(i) - mean) * (this.e(i - lag) - mean);
      raw[lag] = s / (n - lag);
    }
    let best = 0, bestLag = 0;
    const scores = new Float64Array(maxLag + 2);
    for (let lag = minLag; lag <= maxLag; lag++) {
      let v = (raw[lag] + 0.5 * Math.max(0, raw[2 * lag])) / 1.5;
      const oct = Math.log2((60 * hps / lag) / 100);
      v *= Math.exp(-0.5 * (oct * oct) / 0.36);
      scores[lag] = v;
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
    const loudEnough = this.level > 0.0001;                                 // about -40 dB: actual music, not hiss
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
    this.period = this.period > 0 && Math.abs(newPeriod - this.period) / this.period < 0.04 ? this.period * 0.5 + newPeriod * 0.5 : newPeriod;
    this.anchor = newAnchor;
  }
  nextBeat(sample) {
    if (this.period <= 0) return null;
    return this.anchor + Math.ceil((sample - this.anchor) / this.period) * this.period;
  }
}

// how often a chop can start (in beats) and how likely it is each time; heavy also picks the wilder moves more
const CHOPS = { off: null, light: { every: 4, chance: 0.45 }, heavy: { every: 4, chance: 1 } };

/** The moves, as cuts between the live record and copies that are behind. Each cut: [length, delay] in beats.
    The song's own timeline keeps running underneath, like the second deck. */
const MOVES = {
  repeatBeat: [[1, 1]],                        // hear the last beat again
  runBack: [[2, 2]],                           // run back the last two beats (about a line)
  stutter: [[0.5, 0.5], [0.5, 1], [0.5, 1.5]], // "ch-ch-ch": the same half beat three times
  doubleUp: [[1, 1], [1, 2]],                  // the last beat twice
  backItUp: [[4, 4]],                          // back up a whole bar
};
const PICKS = {
  light: [["runBack", 0.45], ["repeatBeat", 0.3], ["stutter", 0.15], ["doubleUp", 0.1]],
  heavy: [["stutter", 0.3], ["runBack", 0.25], ["doubleUp", 0.2], ["repeatBeat", 0.1], ["backItUp", 0.15]],
};

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
    this.written = 0; this.beatsSeen = 0; this.lastBeat = -1; this.active = null; this.history = []; this.cooldownUntil = 0;
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
    const f = this.fade, end = chop.start + chop.length;
    if (start >= end + f) { this.active = null; this.cooldownUntil = end + this.tracker.period; return; }
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
