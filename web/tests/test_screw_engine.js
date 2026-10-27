/* Screw engine checks (run: node test_screw_engine.js). Same cases as the app tests plus harder songs. */
const { Chopper } = require(require("path").join(__dirname, "..", "site", "chop-worklet.js"));
const sr = 44100;
function beat(bpm, seconds, offset = 0.137, seed = 7) {
  const n = Math.floor(seconds * sr), out = new Float32Array(n), p = 60 / bpm;
  let s = seed; const noise = () => { s = (s * 1103515245 + 12345) % 2147483648; return s / 2147483648 - 0.5; };
  for (let k = 0; ; k++) {
    const t0 = offset + k * p; if (t0 >= seconds) break;
    const st = Math.floor(t0 * sr), kick = k % 2 === 0;
    for (let i = 0; i < 0.25 * sr && st + i < n; i++) {
      const t = i / sr;
      out[st + i] += kick ? 0.9 * Math.sin(2 * Math.PI * (55 + 90 * Math.exp(-t * 30)) * t) * Math.exp(-t * 9)
                          : noise() * 0.6 * Math.exp(-t * 22) + 0.3 * Math.sin(2 * Math.PI * 190 * t) * Math.exp(-t * 18);
    }
    for (let h = 0; h < 2; h++) { const hs = Math.floor((t0 + h * p / 2) * sr); for (let i = 0; i < 0.04 * sr && hs + i < n; i++) out[hs + i] += noise() * 0.18 * Math.exp(-i / sr * 90); }
  }
  for (let i = 0; i < n; i++) out[i] += 0.12 * Math.sin(2 * Math.PI * 41.2 * i / sr) + noise() * 0.01;
  return out;
}
function run(x, amount, seed = 42) {
  const c = new Chopper(sr, seed), l = Float32Array.from(x), r = Float32Array.from(x);
  for (let i = 0; i < x.length; i += 128) { const n = Math.min(128, x.length - i); c.process([l.subarray(i, i + n), r.subarray(i, i + n)], n, amount); }
  return { c, l };
}
let ok = true;
for (const [bpm, off] of [[72, .1], [80, .3], [84, .21], [90, .137], [100, .05], [120, .4], [150, .2]]) {
  const { c } = run(beat(bpm, 14, off), "off");
  const p = 60 / bpm * sr, nb = c.tracker.nextBeat(12 * sr);
  let err = (nb - off * sr) % p; if (err > p / 2) err -= p; if (err < -p / 2) err += p;
  const half = Math.abs(c.tracker.bpm / bpm - 0.5) < 0.015;
  const good = (Math.abs(c.tracker.bpm - bpm) / bpm < 0.015 || (bpm >= 140 && half));
  let phaseErr = Math.abs(err) / sr * 1000;
  if (half) { const p2 = 2 * p; let e2 = (nb - off * sr) % p; phaseErr = Math.min(Math.abs(e2), p - Math.abs(e2)) / sr * 1000; }
  console.log(`${bpm} BPM -> ${c.tracker.bpm.toFixed(2)} conf ${c.tracker.confidence.toFixed(2)} phase err ${phaseErr.toFixed(1)}ms ${good && phaseErr < 15 ? "OK" : "BAD"}`);
  if (!(good && phaseErr < 15)) ok = false;
}
const x = beat(84, 60, 0.21);
const { c, l } = run(x, "heavy");
const p = 60 / 84 * sr; let worst = 0, repeatOk = true;
const moves = {};
for (const ch of c.history) {
  moves[ch.name] = (moves[ch.name] || 0) + 1;
  let e = (ch.start - 0.21 * sr) % p; if (e > p / 2) e -= p; if (e < -p / 2) e += p; worst = Math.max(worst, Math.abs(e) / sr * 1000);
  if (ch.start + ch.length + 600 >= x.length) continue;
  for (const g of ch.segs) {   // in the middle of every cut you hear exactly the earlier audio
    const mid = Math.floor(g.at + g.len / 2), d = Math.round(g.delay);
    for (let i = mid - 100; i < mid + 100; i += 7) if (Math.abs(l[i] - x[i - d]) > 1e-6) repeatOk = false;
  }
  const after = Math.floor(ch.start + ch.length) + 600;
  if (Math.abs(l[after] - x[after]) > 1e-6) repeatOk = false;
}
let inMax = 0; for (let i = 1; i < x.length; i++) inMax = Math.max(inMax, Math.abs(x[i] - x[i - 1]));
let cutMax = 0;
for (const ch of c.history) for (const edge of [...ch.segs.map((g) => Math.floor(g.at)), Math.floor(ch.start + ch.length)])
  for (let i = Math.max(1, edge - 400); i < Math.min(l.length, edge + 400); i++) cutMax = Math.max(cutMax, Math.abs(l[i] - l[i - 1]));
const perMin = c.history.length;
console.log(`chops ${perMin}/min (${Object.entries(moves).map(([k, v]) => k + " " + v).join(", ")}), worst off-beat ${worst.toFixed(1)}ms, repeats exact ${repeatOk}, first at ${(c.history[0]?.start / sr).toFixed(1)}s, cut jump ${cutMax.toFixed(3)} vs music ${inMax.toFixed(3)}`);
const light = run(x, "light").c.history.length;
console.log(`light: ${light}/min`);
if (perMin < 15 || light < 8 || Object.keys(moves).length < 4) { console.log("not enough chops / variety"); process.exitCode = 1; }
const t0 = Date.now(); run(beat(90, 60), "heavy"); console.log(`60 s stereo in ${Date.now() - t0} ms`);
if (!ok || worst > 15 || !repeatOk || cutMax > inMax * 1.2) process.exitCode = 1;
