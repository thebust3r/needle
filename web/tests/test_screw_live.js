/* Live chops: you tap, it cuts back in time (run: node test_screw_live.js). */
const { Chopper } = require(require("path").join(__dirname, "..", "site", "chop-worklet.js"));
const sr = 44100, bpm = 84, off = 0.21, P = 60 / bpm * sr;
function beat(seconds, seed = 7) {
  const n = Math.floor(seconds * sr), out = new Float32Array(n), p = 60 / bpm;
  let s = seed; const noise = () => { s = (s * 1103515245 + 12345) % 2147483648; return s / 2147483648 - 0.5; };
  for (let k = 0; ; k++) {
    const t0 = off + k * p; if (t0 >= seconds) break;
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
let pass = 0, fail = 0;
const check = (name, ok, info = "") => { ok ? pass++ : fail++; console.log(`${ok ? "PASS" : "FAIL"} ${name}${info !== "" ? "   [" + info + "]" : ""}`); };

// events: [seconds, fn(chopper)] run between 128-sample blocks, like messages arriving on the audio thread
function run(x, events) {
  const c = new Chopper(sr, 5), l = Float32Array.from(x), r = Float32Array.from(x), results = [];
  let e = 0;
  for (let i = 0; i < x.length; i += 128) {
    while (e < events.length && events[e][0] * sr <= i) { results.push(events[e][1](c, i)); e++; }
    const n = Math.min(128, x.length - i);
    c.process([l.subarray(i, i + n), r.subarray(i, i + n)], n, "live");
  }
  return { c, l, results };
}
const x = beat(40);

// 1. nothing happens by itself, and taps before the beat is found are ignored
{
  const { c, l, results } = run(x, [[1.0, (c) => c.trigger("repeatBeat")]]);
  check("no taps = no chops (live never chops on its own)", c.history.length === 0 || results[0] === true);
  check("tap before the beat is found does nothing", results[0] === false);
  check("song untouched", l.every((v, i) => v === x[i]));
}

// 2. taps at awkward moments: each starts right away (or snaps to a beat that's about to land) and repeats real audio
const moves = ["repeatBeat", "stutter", "runBack", "doubleUp", "backItUp"];
const taps = moves.map((m, k) => [8 + k * 4.37, (c, i) => ({ ok: c.trigger(m), i, m })]);
{
  const { c, l, results } = run(x, taps);
  check("every tap fires once the beat is locked", results.every((r) => r.ok), results.map((r) => r.ok).join(","));
  check("one chop per tap", c.history.length === moves.length, c.history.length);
  let worstWait = 0, exact = true, grid = true;
  c.history.forEach((ch, k) => {
    const wait = (ch.start - results[k].i) / sr * 1000;
    worstWait = Math.max(worstWait, wait);
    for (const g of ch.segs) {
      const beats = g.delay / P; if (Math.abs(beats * 2 - Math.round(beats * 2)) > 0.03) grid = false;
      const mid = Math.round(g.at + g.len / 2), d = Math.round(g.delay);
      for (let i = mid - 100; i < mid + 100; i += 7) if (Math.abs(l[i] - x[i - d]) > 1e-6) exact = false;
    }
    const after = Math.round(ch.start + ch.length) + 600;
    if (Math.abs(l[after] - x[after]) > 1e-6) exact = false;
  });
  check("responds fast (starts within 125 ms of the tap)", worstWait <= 125, worstWait.toFixed(0) + " ms");
  check("cuts go back whole or half beats, so it stays in time", grid);
  check("you hear the real earlier audio, then the song comes back", exact);
  let jumpMax = 0, musicMax = 0;
  for (let i = 1; i < x.length; i++) musicMax = Math.max(musicMax, Math.abs(x[i] - x[i - 1]));
  for (const ch of c.history) for (const edge of [...ch.segs.map((g) => Math.round(g.at)), Math.round(ch.start + ch.length)])
    for (let i = edge - 300; i < edge + 300; i++) jumpMax = Math.max(jumpMax, Math.abs(l[i] - l[i - 1]));
  check("no clicks at the cuts", jumpMax <= musicMax * 1.2, `${jumpMax.toFixed(3)} vs ${musicMax.toFixed(3)}`);
}

// 3. snapping: a tap 50 ms before a beat waits for it
{
  const probe = run(x.subarray(0, Math.floor(10 * sr)), []).c;
  const nb = probe.tracker.nextBeat(10 * sr), tapAt = (nb - 0.05 * sr) / sr;
  const { c } = run(x, [[tapAt, (c) => c.trigger("repeatBeat")]]);
  const ch = c.history[0];
  const err = ch ? Math.abs(ch.start - nb) / sr * 1000 : 999;
  check("tap just before a beat lands on the beat", err < 15, err.toFixed(1) + " ms");
}

// 4. mashing: taps during a chop line up right after it
{
  const { c, results } = run(x, [[10, (c) => c.trigger("stutter")], [10.2, (c) => c.trigger("repeatBeat")], [10.4, (c) => c.trigger("repeatBeat")]]);
  check("taps during a chop chain onto it", results.every(Boolean) && c.history.length === 1 && c.history[0].segs.length === 5, c.history.map((h) => h.segs.length).join(","));
}

// 5. hold the loop pad for 3 s: the same beat over and over, then back to the song
{
  const { c, l } = run(x, [[12, (c) => c.trigger("loop", true)], [15, (c) => c.release()]]);
  const ch = c.history[0];
  const passes = ch ? ch.segs.length : 0;
  check("holding loops the beat for as long as you hold", passes >= Math.floor(3 * sr / P) && passes <= Math.ceil(3 * sr / P) + 2, `${passes} passes in 3 s`);
  let same = true;
  if (ch) for (const g of ch.segs) {
    const src = g.at - g.delay;                 // where in the song this pass reads from
    if (Math.abs(src - (ch.segs[0].at - ch.segs[0].delay)) > 2) same = false;
    const mid = Math.round(g.at + g.len / 2), d = Math.round(g.delay);
    if (Math.abs(l[mid] - x[mid - d]) > 1e-6) same = false;
  }
  check("every pass is the same beat", same);
  const end = ch ? Math.round(ch.start + ch.length) + 600 : 0;
  check("let go and it's back to the song", ch && Math.abs(l[end] - x[end]) < 1e-6 && ch.start + ch.length < 15.5 * sr + P);
}
// 6. a quick tap on the loop pad is just one repeat
{
  const { c } = run(x, [[12, (c) => c.trigger("loop", true)], [12.05, (c) => c.release()]]);
  check("quick tap on loop = one repeat", c.history[0] && c.history[0].segs.length === 1);
}
console.log(`\n${pass} passed, ${fail} failed`);
if (fail) process.exitCode = 1;
