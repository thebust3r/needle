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

// 2. taps at awkward moments: each starts right away (or snaps to a beat that's about to land), repeats real audio,
//    and the song then carries on from where the chop left off
const f = Math.max(64, Math.floor(sr * 0.006));
const moves = ["repeatBeat", "stutter", "runBack", "doubleUp", "backItUp"];
const taps = moves.map((m, k) => [8 + k * 4.37, (c, i) => ({ ok: c.trigger(m), i, m })]);
function exactAndResumes(ch, l) {
  let exact = true;
  for (const g of ch.played) for (let t = f; t < g.len - f; t += 7) if (g.oc + t < l.length && Math.abs(l[g.oc + t] - x[g.from + t]) > 1e-6) exact = false;
  const last = ch.played[ch.played.length - 1], resume = last.from + last.len;
  let resumes = Math.abs(resume - ch.played[0].at) <= 2;
  for (let t = 0; t < 300; t += 7) if (ch.end + t < l.length && Math.abs(l[ch.end + t] - x[resume + t]) > 1e-6) resumes = false;
  return { exact, resumes };
}
{
  const { c, l, results } = run(x, taps);
  check("every tap fires once the beat is locked", results.every((r) => r.ok), results.map((r) => r.ok).join(","));
  check("one chop per tap", c.history.length === moves.length, c.history.length);
  let worstWait = 0, exact = true, resumes = true, grid = true;
  c.history.forEach((ch, k) => {
    worstWait = Math.max(worstWait, (ch.played[0].oc - results[k].i) / sr * 1000);
    for (const j of ch.jumps) { const b = j.J / P; if (Math.abs(b * 2 - Math.round(b * 2)) > 0.03) grid = false; }
    const r = exactAndResumes(ch, l); exact = exact && r.exact; resumes = resumes && r.resumes;
  });
  check("responds fast (starts within 125 ms of the tap)", worstWait <= 125, worstWait.toFixed(0) + " ms");
  check("jumps back whole or half beats, so it stays in time", grid);
  check("you hear the real earlier audio", exact);
  check("then the song picks up where the chop left off", resumes);
  const added = c.lag / sr, expected = (1 + 1.5 + 2 + 2 + 4) * P / sr;
  check("the song got longer by exactly the chops", Math.abs(added - expected) < 0.01, `${added.toFixed(2)} s vs ${expected.toFixed(2)} s`);
  let jumpMax = 0, musicMax = 0;
  for (let i = 1; i < x.length; i++) musicMax = Math.max(musicMax, Math.abs(x[i] - x[i - 1]));
  for (const ch of c.history) for (const g of ch.played) for (let i = g.oc - 300; i < g.oc + 300; i++) jumpMax = Math.max(jumpMax, Math.abs(l[i] - l[i - 1]));
  check("no clicks at the cuts", jumpMax <= musicMax * 1.2, `${jumpMax.toFixed(3)} vs ${musicMax.toFixed(3)}`);
}

// 3. snapping: a tap 50 ms before a beat waits for it
{
  const probe = run(x.subarray(0, Math.floor(10 * sr)), []).c;
  const nb = probe.tracker.nextBeat(10 * sr), tapAt = (nb - 0.05 * sr) / sr;
  const { c } = run(x, [[tapAt, (c) => c.trigger("repeatBeat")]]);
  const ch = c.history[0];
  const err = ch ? Math.abs(ch.played[0].at - nb) / sr * 1000 : 999;
  check("tap just before a beat lands on the beat", err < 15, err.toFixed(1) + " ms");
}

// 4. mashing: taps during a chop line up right after it
{
  const { c, results } = run(x, [[10, (c) => c.trigger("stutter")], [10.2, (c) => c.trigger("repeatBeat")], [10.4, (c) => c.trigger("repeatBeat")]]);
  check("taps during a chop chain onto it", results.every(Boolean) && c.history.length === 1 && c.history[0].jumps.length === 5, c.history.map((h) => h.jumps.length).join(","));
}

// 5. hold the loop pad for 3 s: the same beat over and over, then the song carries on from there
{
  const { c, l } = run(x, [[12, (c) => c.trigger("loop", true)], [15, (c) => c.release()]]);
  const ch = c.history[0];
  const passes = ch ? ch.played.length : 0;
  check("holding loops the beat for as long as you hold", passes >= Math.floor(3 * sr / P) && passes <= Math.ceil(3 * sr / P) + 2, `${passes} passes in 3 s`);
  const same = ch && ch.played.every((g) => Math.abs(g.from - ch.played[0].from) <= 2);
  check("every pass is the same beat", same);
  const r = ch ? exactAndResumes(ch, l) : {};
  check("let go and the song picks up right after that beat", r.exact && r.resumes && ch.end < 15.2 * sr + P);
}
// 6. a quick tap on the loop pad is just one repeat
{
  const { c } = run(x, [[12, (c) => c.trigger("loop", true)], [12.05, (c) => c.release()]]);
  check("quick tap on loop = one repeat", c.history[0] && c.history[0].jumps.length === 1);
}

// 7. pausing holds your place, even when you're behind the song because of chops
{
  const c = new Chopper(sr, 5), out = [];
  const feed = (src, n) => { const a = Float32Array.from(src.subarray(0, n)), b = Float32Array.from(a); c.process([a, b], n, "live"); out.push(...a); };
  let i = 0;
  for (; i < 12 * sr; i += 128) feed(x.subarray(i), 128);
  c.trigger("backItUp");
  for (; i < 16 * sr; i += 128) feed(x.subarray(i), 128);
  const lagBefore = c.lag, heard = c.rp;
  feed(new Float32Array(128), 128); feed(new Float32Array(128), 128);   // the element went quiet a moment before the pause message
  c.pause();
  const zeros = new Float32Array(128);
  for (let k = 0; k < 200; k++) feed(zeros, 128);                         // paused for ~0.6 s
  const pausedSilent = out.slice(out.length - 200 * 128).every((v) => v === 0);
  c.play();
  for (let k = 0; k < 20; k++) feed(zeros, 128);                          // the song takes a moment to start again
  const start = out.length;
  for (; i < 20 * sr; i += 128) feed(x.subarray(i), 128);
  check("paused = quiet", pausedSilent);
  // while the song starts back up you keep hearing it from memory, so you catch up by just that moment
  check("you're still behind the song after a pause (minus the start-up moment)", Math.abs(c.lag - (lagBefore - 20 * 128)) < 3 * 128, `${(lagBefore / sr).toFixed(2)} s -> ${(c.lag / sr).toFixed(2)} s`);
  // it plays on from exactly where you were, right away, with no gap now or later
  const resumeIdx = start - 20 * 128, from = heard + 2 * 128;
  let cont = true;
  for (let t = 0; t < 3 * sr && resumeIdx + t < out.length; t += 31) if (Math.abs(out[resumeIdx + t] - x[from + t]) > 1e-6) { cont = false; break; }
  check("and carries on from the same spot with no gap", cont);
}
console.log(`\n${pass} passed, ${fail} failed`);
if (fail) process.exitCode = 1;
