/* Harder songs: swing, noise, quiet intro, synth pad, drifting tempo, fast and slow. Run: node test_screw_hard.js */
const { Chopper } = require(require("path").join(__dirname, "..", "site", "chop-worklet.js"));
const sr = 44100;
function song(bpm, seconds, { offset = 0.2, swing = 0, noise = 0.01, intro = 0, pad = 0, drift = 0, seed = 3 } = {}) {
  const n = Math.floor(seconds * sr), out = new Float32Array(n);
  let s = seed; const rnd = () => { s = (s * 1103515245 + 12345) % 2147483648; return s / 2147483648 - 0.5; };
  let t0 = intro + offset, k = 0; const beats = [];
  while (t0 < seconds) {
    beats.push(t0);
    const p = 60 / (bpm * (1 + drift * (t0 / seconds)));
    const st = Math.floor(t0 * sr), kick = k % 2 === 0 || (k % 8 === 7);
    for (let i = 0; i < 0.25 * sr && st + i < n; i++) {
      const t = i / sr;
      out[st + i] += kick ? 0.8 * Math.sin(2 * Math.PI * (50 + 80 * Math.exp(-t * 25)) * t) * Math.exp(-t * 7)
                          : rnd() * 0.5 * Math.exp(-t * 20);
    }
    for (let h = 0; h < 4; h++) { const hs = Math.floor((t0 + h * p / 4 + (h % 2 ? swing * p / 4 : 0)) * sr); for (let i = 0; i < 0.03 * sr && hs + i < n; i++) out[hs + i] += rnd() * 0.12 * Math.exp(-i / sr * 120); }
    t0 += p; k++;
  }
  for (let i = 0; i < n; i++) {
    const t = i / sr;
    out[i] = (t < intro ? 0.05 * out[i] : out[i]) + noise * rnd() * 2 + pad * Math.sin(2 * Math.PI * 220 * t) * (0.5 + 0.5 * Math.sin(t * 0.7));
  }
  return { x: out, beats };
}
function check(name, bpm, opts) {
  const { x, beats } = song(bpm, 60, opts);
  const c = new Chopper(sr, 11), l = Float32Array.from(x);
  for (let i = 0; i < x.length; i += 128) { const m = Math.min(128, x.length - i); c.process([l.subarray(i, i + m)], m, "heavy"); }
  let worst = 0;
  for (const ch of c.history) { if (ch.start >= x.length) continue; const t = ch.start / sr; const d = Math.min(...beats.map((b) => Math.abs(b - t))); worst = Math.max(worst, d * 1000); }
  const ratio = c.tracker.bpm / bpm;
  const bad = c.history.filter((ch) => ch.start < x.length && Math.min(...beats.map((b) => Math.abs(b - ch.start / sr))) > 0.02).map((ch) => (ch.start / sr).toFixed(2));
  if (bad.length) process.exitCode = 1;
  if (worst >= 20) process.exitCode = 1;
  console.log(`${name.padEnd(28)} found ${c.tracker.bpm.toFixed(1)} (x${ratio.toFixed(2)}) conf ${c.tracker.confidence.toFixed(2)} chops ${c.history.length} worst ${worst.toFixed(1)}ms ${worst < 20 ? "OK" : "BAD"}`);
}
check("swing", 88, { swing: 0.35 });
check("noisy", 92, { noise: 0.12 });
check("quiet 8s intro", 80, { intro: 8 });
check("loud synth pad", 76, { pad: 0.4 });
check("tempo drifts 2%", 90, { drift: 0.02 });
check("fast trap 140", 140, {});
check("slow 64", 64, {});
