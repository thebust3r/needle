const fs = require("fs"), path = require("path"), D = process.argv[2];
const { Chopper } = require(process.argv[3] || path.join(__dirname, "..", "..", "site", "chop-worklet.js"));
const sr = 44100;
function feed(name, x) {
  const c = new Chopper(sr, 1); let maxc = 0, locked = 0, n = 0;
  for (let i = 0; i < x.length; i += 128) { const k = Math.min(128, x.length - i); c.process([x.subarray(i, i + k)], k, "heavy");
    if (i % 22050 < 128 && i > 4 * sr) { n++; maxc = Math.max(maxc, c.tracker.confidence); if (c.tracker.confidence > 0.15) locked++; } }
  console.log(name.padEnd(16), `max conf ${maxc.toFixed(2)}  locked ${(100 * locked / Math.max(1, n)).toFixed(0)}%  chops ${c.history.length}  (${(x.length / sr).toFixed(0)} s)`);
}
for (const f of fs.readdirSync(path.join(D, "neg"))) { const b = fs.readFileSync(path.join(D, "neg", f)); feed(f, new Float32Array(b.buffer, b.byteOffset, b.length / 4).slice()); }
let s = 5; const rnd = () => { s = (s * 1103515245 + 12345) % 2147483648; return s / 2147483648 - 0.5; };
const N = 30 * sr, noise = new Float32Array(N), pad = new Float32Array(N), sil = new Float32Array(N);
for (let i = 0; i < N; i++) { const t = i / sr; noise[i] = (Math.random() - 0.5) * 0.3 + rnd() * 0; pad[i] = 0.2 * (Math.sin(2 * Math.PI * 220 * t) + Math.sin(2 * Math.PI * 277 * t) + Math.sin(2 * Math.PI * 330 * t)) * (0.7 + 0.3 * Math.sin(t * 0.5)); sil[i] = rnd() * 0.0005; }
feed("white noise", noise); feed("held chord", pad); feed("near silence", sil);
