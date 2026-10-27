// Scorecard for the live beat tracker on real songs. node score.js <dir> [module]
const fs = require("fs"), path = require("path");
const dir = process.argv[2], mod = process.argv[3] || require("path").join(__dirname, "..", "..", "site", "chop-worklet.js");
delete require.cache[require.resolve(mod)];
const { Chopper } = require(mod);
const sr = +(process.env.SR || 44100), ref = JSON.parse(fs.readFileSync(path.join(dir, "beats.json")));
const REF_BPM = { "442789__lena": 146.4, "Karissa_Hobb": 117.7, "Kevin_MacLeo": 130.0, "admiralbob77": 135.9 };
let totals = { lock: 0, right: 0, phase: 0, n: 0 };
for (const f of fs.readdirSync(dir).filter((f) => f.endsWith(".f32"))) {
  const name = f.replace(".f32", ""), b = fs.readFileSync(path.join(dir, f)), st = new Float32Array(b.buffer, b.byteOffset, b.length / 4);
  const n = st.length / 2, L = new Float32Array(n);
  for (let i = 0; i < n; i++) L[i] = (st[2 * i] + st[2 * i + 1]) / 2;
  for (const rate of [1, 0.8]) {
    const step = rate * 44100 / sr, m = Math.floor(n / step), l = new Float32Array(m);
    for (let i = 0; i < m; i++) { const x = i * step, k = Math.floor(x), t = x - k; l[i] = L[k] * (1 - t) + (L[k + 1] || 0) * t; }
    const beats = ref[`${name}.x1.0.beats.npy`].map((b) => b / rate), trueBpm = REF_BPM[name] * rate;
    const c = new Chopper(sr, 3);
    const seen = {}, errs = [];
    let samples = 0, locked = 0, right = 0, phaseOk = 0, switches = 0, prevBpm = 0;
    for (let i = 0; i < m; i += 128) {
      const k = Math.min(128, m - i); c.process([l.subarray(i, i + k)], k, "live");
      if (i % 22050 < 128 && i > 8 * sr) {
        samples++;
        const t = c.tracker, ok = t.confidence > 0.15 && t.bpm > 0;
        if (prevBpm && t.bpm && Math.abs(t.bpm / prevBpm - 1) > 0.03) switches++;
        prevBpm = t.bpm; seen[Math.round(t.bpm)] = (seen[Math.round(t.bpm)] || 0) + 1;
        if (!ok) continue;
        locked++;
        const r = t.bpm / trueBpm, rr = [0.5, 1, 2].find((v) => Math.abs(r / v - 1) < 0.03);
        if (!rr) continue;
        right++;
        // the next predicted beat should be close to a real beat (or exactly between two, if it's double time)
        const nb = t.nextBeat(i + k) / sr, grid = rr === 2 ? 0.5 : 1;
        const P = 60 / trueBpm;
        let best = 9, signed = 0;
        for (const bt of beats) for (let g = 0; g < 1; g += grid) { const d = nb - (bt + g * P); if (Math.abs(d) < best) { best = Math.abs(d); signed = d; } }
        if (best < 0.05) phaseOk++;
        errs.push(Math.round(signed * 1000));
      }
    }
    totals.lock += locked; totals.right += right; totals.phase += phaseOk; totals.n += samples;
    console.log(`${name.padEnd(13)} x${rate}  locked ${(100 * locked / samples).toFixed(0).padStart(3)}%  right tempo ${(100 * right / samples).toFixed(0).padStart(3)}%  on the beat ${(100 * phaseOk / samples).toFixed(0).padStart(3)}%  tempo changes ${switches}` + (process.env.E ? "  err(ms) med " + errs.sort((a, b) => a - b)[errs.length >> 1] + " q " + errs[errs.length >> 2] + ".." + errs[(3 * errs.length) >> 2] : "") + (process.env.V ? "  " + Object.entries(seen).sort((a, b) => b[1] - a[1]).slice(0, 4).map(([k, v]) => k + ":" + v).join(" ") : ""));
  }
}
console.log(`ALL  locked ${(100 * totals.lock / totals.n).toFixed(0)}%  right ${(100 * totals.right / totals.n).toFixed(0)}%  on beat ${(100 * totals.phase / totals.n).toFixed(0)}%`);
