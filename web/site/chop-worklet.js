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
    this.envKick = new Float32Array(this.maxHops);    // low-end hits (kick, 808)
    this.envSnare = new Float32Array(this.maxHops);   // mid-high hits (snare, clap)
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
    this.kickLog = new Float32Array(512);         // how hard the kick / snare / everything hit on each of those beats
    this.snareLog = new Float32Array(512);
    this.energyLog = new Float32Array(512);
    this.reset();
  }
  reset() {
    this.envCount = 0; this.fill = 0; this.period = 0; this.anchor = 0; this.confidence = 0; this.samplesSeen = 0;
    this.sinceEstimate = 0; this.level = 0; this.env.fill(0); this.buf.fill(0); this.prevBands.fill(0); this.A.fill(0);
    this.hist.fill(0); this.histSum = 0; this.estimates = 0;
    this.logCount = 0; this.logEnd = 0; this.barPhase = 0; this.barSure = 0;
    this.envKick.fill(0); this.envSnare.fill(0);
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
    let flux = 0, kick = 0, snare = 0;
    for (let b = 0; b < 24; b++) {
      let s = 0; const a = this.edges[b], e = Math.max(a + 1, this.edges[b + 1]);
      for (let k = a; k < e; k++) s += Math.sqrt(this.re[k] * this.re[k] + this.im[k] * this.im[k]);
      const v = Math.log1p(10 * s / (e - a));
      const d = Math.max(0, v - this.prevBands[b]);
      flux += d;
      if (b < 6) kick += d;                 // ~40-160 Hz
      else if (b >= 11 && b < 19) snare += d;   // ~500 Hz - 3.5 kHz
      this.prevBands[b] = v;
    }
    flux /= 24;
    // take away the slowly-moving part (busy passages vs sparse ones), keep the hits
    const h = this.hist, k = this.envCount % 16;
    this.histSum += flux - h[k]; h[k] = flux;
    const o = Math.max(0, flux - this.histSum / 16);
    this.env[this.envCount % this.maxHops] = o;
    this.envKick[this.envCount % this.maxHops] = kick / 6;
    this.envSnare[this.envCount % this.maxHops] = snare / 8;
    this.envCount++;
    const hps = this.sampleRate / this.hop;
    if (++this.sinceEstimate >= Math.floor(0.25 * hps) && this.envCount >= Math.floor(3 * hps)) { this.sinceEstimate = 0; this.estimate(); }
  }
  band(arr, i) { return i < 0 || i >= this.envCount || this.envCount - i > this.maxHops ? 0 : arr[i % this.maxHops]; }
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
        const last = this.logCount ? this.log[(this.logCount - 1) % 512] : -Infinity, expect = last + this.period;
        // keep the count continuous: one beat about a beat after the last. A grid that slid half a beat doesn't
        // add an extra beat, and a gap gets filled in, so "the 1" never moves.
        if (this.logCount && b <= expect - this.period * 0.45) { b += this.period; continue; }      // already have it
        if (this.logCount && b > expect + this.period * 0.55 && b - last < 4 * this.period) b = expect;   // fill a gap
        if (b - last > this.period * 0.5) {
          // how hard things hit right on this beat (strongest within ±1 analysis step), and how busy the beat was
          const h = Math.round((b - (this.N - this.hop)) / this.hop), k = this.logCount % 512;
          let kk = 0, sn = 0, en = 0;
          for (let j = h - 1; j <= h + 1; j++) { kk = Math.max(kk, this.band(this.envKick, j)); sn = Math.max(sn, this.band(this.envSnare, j)); }
          const span = Math.max(1, Math.round(this.period / this.hop));
          for (let j = h; j < h + span; j++) en += this.e(j);
          this.log[k] = b; this.kickLog[k] = kk; this.snareLog[k] = sn; this.energyLog[k] = en / span;
          this.logCount++;
          this.findBar();
        }
        b += this.period;
      }
      this.logEnd = until;
    }
  }
  /** Which beat is the "1": kicks land on 1 (and often 3), snares and claps on 2 and 4. Looks at the last 8 bars and
      only changes its mind when another answer is clearly better. Bars are counted by beat number in the log. */
  findBar() {
    const n = Math.min(this.logCount, 32);
    if (n < 8) return;
    const score = new Float64Array(4);
    for (let i = this.logCount - n; i < this.logCount; i++) {
      const k = i % 512, pos = ((i % 4) + 4) % 4;
      for (let q = 0; q < 4; q++) {
        const d = (pos - q + 4) % 4;      // this beat's place in the bar if the bar starts at q
        score[q] += d === 0 ? this.kickLog[k] * 1.0 - this.snareLog[k] * 0.4
                  : d === 2 ? this.kickLog[k] * 0.5 - this.snareLog[k] * 0.2
                  : this.snareLog[k] * 0.6 - this.kickLog[k] * 0.2;
      }
    }
    let best = 0; for (let q = 1; q < 4; q++) if (score[q] > score[best]) best = q;
    const cur = score[this.barPhase], margin = Math.abs(cur) * 0.15 + 1e-6;
    if (best !== this.barPhase && score[best] > cur + margin) this.barPhase = best;
    const sorted = [...score].sort((a, b) => b - a);
    this.barSure = sorted[0] > 0 ? Math.min(1, (sorted[0] - sorted[1]) / sorted[0]) : 0;
  }
  /** The beat at or after `sample` with its number (beats count up through the song; the bar starts where
      (number - barPhase) % 4 === 0). */
  beatAt(sample) {
    if (this.period <= 0) return null;
    const n = Math.min(this.logCount, 512);
    if (n && sample <= this.log[(this.logCount - 1) % 512] && sample >= this.log[(this.logCount - n) % 512]) {
      let k = this.logCount - 1;
      while (k > this.logCount - n && this.log[(k - 1) % 512] >= sample) k--;
      return { pos: this.log[k % 512], num: k };
    }
    if (!n) return { pos: this.grid(sample), num: -1 };
    // just ahead of the newest found beat: carry on from it, so the count (and where the 1 is) stays put
    const lastPos = this.log[(this.logCount - 1) % 512], k = Math.max(1, Math.ceil((sample - lastPos) / this.period - 1e-9));
    return { pos: lastPos + k * this.period, num: this.logCount - 1 + k };
  }
  /** How busy the music was over the `beats` beats before beat number `num` (0 if unknown). */
  energyBefore(num, beats) {
    let s = 0, c = 0;
    for (let i = num - beats; i < num; i++) if (i >= 0 && i < this.logCount && this.logCount - i <= 512) { s += this.energyLog[i % 512]; c++; }
    return c ? s / c : 0;
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

// Automatic chops: a chance at the top of every `bars` bars (on the "1"), and every move adds whole bars, so the
// song never loses its count. "live" = no automatic chops, you tap them (see trigger).
const CHOPS = { off: null, light: { bars: 4, chance: 0.75 }, heavy: { bars: 2, chance: 0.9 }, live: null };

/** The moves, as [length, delay] pairs in beats (the playhead jumps back so it's `delay` behind, plays `length`).
    The song carries on from where the chop started once it's done. */
const MOVES = {
  // live pads (you choose when)
  repeatBeat: [[1, 1]],                        // hear the last beat again
  runBack: [[2, 2]],                           // run back the last two beats (about a line)
  stutter: [[0.5, 0.5], [0.5, 1], [0.5, 1.5]], // "ch-ch-ch": the same half beat three times
  doubleUp: [[1, 1], [1, 2]],                  // the last beat twice
  backItUp: [[4, 4]],                          // back up a whole bar
  loop: [[1, 1]],                              // the last beat, over and over while held
  // automatic: each adds exactly one bar (or two), landing back on the 1
  barRepeat: [[4, 4]],                                                   // the last bar again
  halfBarTwice: [[2, 2], [2, 4]],                                        // the end of the bar, twice
  lastBeat4: [[1, 1], [1, 2], [1, 3], [1, 4]],                           // "ba-ba-ba-ba" into the 1
  stutterBuild: [[1, 1], [1, 2], [0.5, 2.5], [0.5, 3], [0.5, 3.5], [0.5, 4]],   // beat, beat, then faster into the 1
  phraseBack: [[8, 8]],                                                  // run back two bars (end of a phrase)
};
const PICKS = {
  light: [["barRepeat", 0.35], ["halfBarTwice", 0.35], ["lastBeat4", 0.15], ["stutterBuild", 0.15]],
  heavy: [["halfBarTwice", 0.25], ["stutterBuild", 0.25], ["barRepeat", 0.2], ["lastBeat4", 0.15], ["phraseBack", 0.15]],
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
    this.beatsSeen = 0; this.lastBeat = -1; this.active = null; this.history = []; this.cooldownUntil = 0; this.lastMove = null;
    this.holding = false; this.frozen = false; this.resuming = 0;
    this.scr = null;
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
    if (conf && !this.active && !this.scr) this.plan(frames, conf, amount);
    if (this.scr) return this.scratchOut(channels, frames);
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

  /* ---- the turntable: your hand on the record ----
     Like a real record, your hand sets the SPEED: how fast and which way the finger is moving is how fast and which way
     the song plays (twice as fast = twice the speed and pitch, backwards = backwards, still = stopped). The platter has
     weight, so the speed glides (~12 ms) instead of jumping, and a gentle pull keeps the record lined up with where your
     finger actually is. Updates from the screen arrive in bursts (60 a second, or every ~90 ms on an iPhone); because
     they set a speed, not a spot, the sound stays smooth in between. Let go and the motor brings it back up to speed
     (~0.3 s). You can't play past the newest audio or further back than the memory; going past either is reported so
     the player can skip through the song. */
  scratchDown() {
    if (!this.scr) {
      this.active = null; this.holding = false;               // grabbing the record stops any chop
      this.scr = { hold: true, pos: this.rp, grab: this.rp, target: this.rp, hand: 0, vel: 1, g: 1, slope: 0, since: 0 };
    } else { const s = this.scr; Object.assign(s, { hold: true, brake: false, grab: s.pos, target: s.pos, hand: 0, slope: 0, since: 0, lastSpeed: undefined }); }
  }
  /** `offset`: how far the record has been turned since you grabbed it, in samples (positive = forward).
      `speed`: how fast it's turning right now, in playing speeds (1 = normal, 0 = still, -1 = backwards). */
  scratchMove(offset, speed) {
    const s = this.scr;
    if (!s || !s.hold) return;
    s.target = s.grab + offset;
    if (speed === undefined || !isFinite(speed)) return;
    speed = Math.max(-8, Math.min(8, speed));
    // between updates, keep the hand's speed changing the way it was (updates can be ~90 ms apart on an iPhone)
    // (several updates can arrive at once: compare the newest with the newest of the previous batch)
    if (s.since > 64) {
      if (s.lastSpeed !== undefined) s.slope = Math.max(-0.002, Math.min(0.002, (speed - s.lastSpeed) / s.since));
      s.since = 0;
    }
    s.lastSpeed = speed;
    s.hand = speed;
  }
  /** Tape stop: like the Start/Stop button on a deck. The record brakes to a halt (~0.75 s, pitch dropping all the
      way down) and stays stopped until tapeStart(); then the motor spins it back up and the song carries on from there. */
  tapeStop() {
    if (this.scr && this.scr.hold) return false;
    if (!this.scr) {
      this.active = null; this.holding = false;
      this.scr = { hold: false, brake: true, pos: this.rp, grab: this.rp, target: this.rp, hand: 0, vel: 1, g: 1, slope: 0, since: 0 };
    } else this.scr.brake = true;
    return true;
  }
  tapeStart() { if (this.scr && this.scr.brake) { this.scr.brake = false; return true; } return false; }
  get stopped() { return !!(this.scr && this.scr.brake); }

  /** Let go. Returns how far past the ends you tried to go, in samples (for skipping through the song). */
  scratchUp() {
    const s = this.scr;
    if (!s || !s.hold) return 0;
    s.hold = false;
    const lo = this.scratchLow(), hi = this.wp - 2;
    return s.target > hi ? s.target - hi : s.target < lo ? s.target - lo : 0;
  }
  scratchLow() { return Math.max(0, this.wp - this.cap + 8192 + 4096); }
  scratchOut(channels, frames) {
    const s = this.scr, cap = this.cap, nch = channels.length, sr = this.sampleRate;
    const glide = 1 - Math.exp(-1 / (0.012 * sr)), motor = 1 - Math.exp(-1 / (0.06 * sr)), loud = 1 - Math.exp(-1 / (0.01 * sr));
    const pull = 1 / (0.3 * sr);                            // and slowly fix any drift from your finger (~0.3 s)
    const dead = 0.02 * sr, soft = 0.03 * sr, maxAhead = 0.12 * sr, brake = 1 / (0.75 * sr);
    const lo = this.scratchLow(), hi = this.wp - 3;          // (the smooth reading looks 2 samples ahead)
    for (let i = 0; i < frames; i++) {
      if (s.hold) {
        s.since++;
        if (s.since < maxAhead) s.hand = Math.max(-8, Math.min(8, s.hand + s.slope));
        let gap = Math.max(lo, Math.min(hi, s.target)) - s.pos;
        gap = Math.sign(gap) * Math.max(0, Math.abs(gap) - dead);   // close enough: leave it (still = silent)
        let want = Math.max(-8, Math.min(8, s.hand + gap * pull));
        // soft ends: ease to a stop before the newest audio / the start of the memory instead of slamming into them
        want = Math.min(want, (hi - s.pos) / soft); want = Math.max(want, (lo - s.pos) / soft);
        s.vel += (want - s.vel) * glide;
      } else if (s.brake) {
        s.vel = Math.max(0, s.vel - brake);                   // tape stop: winding down
        if (this.wp - s.pos > this.cap - 3 * sr) s.brake = false;   // stopped so long the memory's full: start again
      } else s.vel += (1 - s.vel) * motor;
      s.pos += s.vel;
      if (this.trace) this.trace.push(s.vel);                  // tests: the record's speed, sample by sample
      // at the newest audio you can't go further; with your hand on it that stops the record, while the motor or a
      // tape stop just keep turning at the edge (they're at most a few samples ahead of what's come in)
      if (s.pos > hi) { s.pos = hi; if (s.hold) s.vel = Math.min(s.vel, 0); }
      if (s.pos < lo) { s.pos = lo; if (s.hold) s.vel = Math.max(s.vel, 0); }
      // like a real stylus: the sound is as strong as the record is moving (silent when you hold it still)
      s.g += (Math.min(1, Math.abs(s.vel)) - s.g) * loud;
      // smooth (cubic) reading between samples, so slow and fast scratches sound clean
      const k = Math.floor(s.pos), t = s.pos - k;
      const i0 = (k - 1 + cap) % cap, i1 = k % cap, i2 = (k + 1) % cap, i3 = (k + 2) % cap;
      for (let c = 0; c < nch; c++) {
        const r = this.rings[c], y0 = r[i0], y1 = r[i1], y2 = r[i2], y3 = r[i3];
        const v = y1 + 0.5 * t * (y2 - y0 + t * (2 * y0 - 5 * y1 + 4 * y2 - y3 + t * (3 * (y1 - y2) + y3 - y0)));
        channels[c][i] = v * s.g;
      }
      this.oc++;
      if (!s.hold && !s.brake && Math.abs(s.vel - 1) < 0.004 && s.g > 0.99) {           // back up to speed: play on normally from here
        this.rp = Math.round(s.pos) + 1; this.scr = null; this.changed = true;
        for (let j = i + 1; j < frames; j++) {
          for (let c = 0; c < nch; c++) channels[c][j] = this.rings[c][this.rp % cap];
          this.rp++; this.oc++;
        }
        return;
      }
    }
    this.rp = Math.max(0, Math.floor(s.pos));
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

  /** Automatic chops, placed like a DJ would: on the "1" at the top of every few bars (bigger moves at the end of an
      8-bar phrase), only while the song is going (not in a quiet intro or breakdown), never the same move twice in a
      row, and always adding whole bars so the song keeps its count. */
  plan(frames, conf, amount) {
    const t = this.tracker;
    if (t.confidence <= 0.15 || t.period <= 0 || t.samplesSeen <= this.sampleRate * 4) return;
    const horizon = this.rp + frames + Math.max(this.fade * 2, Math.min(t.period * 0.5, 8192));
    let at = Math.max(this.rp + this.fade + 1, this.lastBeat + t.period * 0.5);
    for (let guard = 0; guard < 8; guard++) {
      const beat = t.beatAt(at);
      if (!beat || beat.pos >= horizon) return;
      at = beat.pos + t.period * 0.5;
      if (beat.pos <= this.lastBeat + t.period * 0.5) continue;
      this.lastBeat = beat.pos;
      if (beat.num < 8) continue;                                 // wait until the bar's been found
      const inBar = ((beat.num - t.barPhase) % 4 + 4) % 4;
      if (inBar !== 0) continue;
      const bar = Math.floor((beat.num - t.barPhase) / 4);
      if (bar % conf.bars !== 0) continue;
      // only while the song is going: the last bar is about as busy as the last few
      const recent = t.energyBefore(beat.num, 4), usual = t.energyBefore(beat.num, 16);
      if (usual <= 0 || recent < usual * 0.6) continue;
      if (this.random() >= conf.chance) continue;
      const phraseEnd = bar % 8 === 0;
      let name = null;
      for (let tries = 0; tries < 6 && !name; tries++) {
        let roll = this.random(), pick = PICKS[amount][0][0];
        for (const [n, w] of PICKS[amount]) { if (roll < w) { pick = n; break; } roll -= w; }
        if (pick === this.lastMove) continue;
        if (pick === "phraseBack" && !phraseEnd) continue;        // two bars back only where a phrase ends
        name = pick;
      }
      if (!name) continue;
      const start = this.oc + Math.round(beat.pos - this.rp);
      const { jumps, end } = this.jumpsFor(name, start, t.period);
      if (!this.fits(jumps.reduce((s, j) => s + j.J, 0))) continue;
      this.active = { name, start, jumps, end, next: 0, beat: beat.num };
      this.lastMove = name;
      this.history.push(this.active);
      if (this.history.length > 64) this.history.shift();
      return;
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
      if (this.amount !== "off" || c.active || c.lag > 0 || c.frozen || c.scr) c.process(output, output[0].length, this.amount);
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
  if (d.scratch === "down") c.scratchDown();
  if (d.scratch === "move") c.scratchMove(d.offset * c.sampleRate, d.speed);
  if (d.scratch === "up") reply({ scratched: c.scratchUp() / c.sampleRate });
  if (d.tape === "stop") { c.tapeStop(); reply({ tape: c.stopped }); }
  if (d.tape === "start") { c.tapeStart(); reply({ tape: c.stopped }); }
}
if (typeof module !== "undefined") module.exports = { BeatTracker, Chopper, chopStats, handleChopMessage };
