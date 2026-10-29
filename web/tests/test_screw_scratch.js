/* The turntable: hold, scratch, let go, fling (run: node test_screw_scratch.js). */
const { Chopper } = require(require("path").join(__dirname, "..", "site", "chop-worklet.js"));
const sr = 44100, bpm = 84, P = 60 / bpm * sr;
let pass = 0, fail = 0;
const check = (name, ok, info = "") => { ok ? pass++ : fail++; console.log(`${ok ? "PASS" : "FAIL"} ${name}${info !== "" ? "   [" + info + "]" : ""}`); };
function beat(seconds) {
  const n = Math.floor(seconds * sr), out = new Float32Array(n), p = 60 / bpm;
  let s = 7; const noise = () => { s = (s * 1103515245 + 12345) % 2147483648; return s / 2147483648 - 0.5; };
  for (let k = 0; ; k++) {
    const t0 = 0.21 + k * p; if (t0 >= seconds) break;
    const st = Math.floor(t0 * sr), kick = k % 2 === 0;
    for (let i = 0; i < 0.25 * sr && st + i < n; i++) { const t = i / sr; out[st + i] += kick ? 0.9 * Math.sin(2 * Math.PI * (55 + 90 * Math.exp(-t * 30)) * t) * Math.exp(-t * 9) : noise() * 0.6 * Math.exp(-t * 22); }
  }
  for (let i = 0; i < n; i++) out[i] += 0.2 * Math.sin(2 * Math.PI * 220 * i / sr);
  return out;
}
const x = beat(40);
// run with events at times (seconds of output), returns output and chopper
function run(events) {
  const c = new Chopper(sr, 5), out = new Float32Array(x.length), log = [];
  let e = 0;
  for (let i = 0; i < x.length; i += 128) {
    while (e < events.length && events[e][0] * sr <= i) { log.push(events[e][1](c, i)); e++; }
    const a = Float32Array.from(x.subarray(i, i + 128));
    c.process([a], a.length, "live");
    out.set(a, i);
  }
  return { c, out, log };
}
const rms = (a, s, e) => { let t = 0; for (let i = s; i < e; i++) t += a[i] * a[i]; return Math.sqrt(t / (e - s)); };

// 1. hold still: silence (no stuck sound, no click)
{
  const { out } = run([[10, (c) => c.scratchDown()], [11, (c) => c.scratchUp()]]);
  const held = rms(out, Math.floor(10.1 * sr), Math.floor(10.9 * sr)), music = rms(out, Math.floor(9 * sr), Math.floor(10 * sr));
  check("holding the record still is silent", held < music * 0.01, `${held.toFixed(4)} vs ${music.toFixed(3)}`);
  let jump = 0, mjump = 0;
  for (let i = Math.floor(9.98 * sr); i < Math.floor(10.05 * sr); i++) jump = Math.max(jump, Math.abs(out[i] - out[i - 1]));
  for (let i = 1; i < x.length; i++) mjump = Math.max(mjump, Math.abs(x[i] - x[i - 1]));
  check("grabbing it doesn't click", jump <= mjump * 1.1, `${jump.toFixed(3)} vs ${mjump.toFixed(3)}`);
}
// 2. scratch back and forth: sound comes from around where you grabbed it, both directions
{
  const evs = [[12, (c) => { c.scratchDown(); return c.rp; }]];
  for (let k = 1; k <= 60; k++) evs.push([12 + k / 60, (c) => { c.scratchMove(-0.25 * sr * Math.sin(2 * Math.PI * 2 * k / 60), -0.25 * 2 * Math.PI * 2 * Math.cos(2 * Math.PI * 2 * k / 60)); return c.scr.pos; }]);
  evs.push([13.02, (c) => c.scratchUp()]);
  const { out, log } = run(evs);
  const grab = log[0], positions = log.slice(1, -1);
  const span = [Math.min(...positions) - grab, Math.max(...positions) - grab].map((v) => (v / sr).toFixed(2));
  check("scratching moves back and forth around the grab point", Math.min(...positions) < grab - 0.1 * sr && Math.max(...positions) > grab + 0.1 * sr, span.join(" .. ") + " s");
  check("and you hear it", rms(out, Math.floor(12.05 * sr), Math.floor(13 * sr)) > 0.02);
  check("a small scratch isn't a skip", log[log.length - 1] === 0);
}
// 3. let go: back up to speed quickly, then exactly the song from that spot, and you're behind by the time you held it
{
  let c2;
  const { c, out } = run([[15, (c) => c.scratchDown()], [15.5, (c) => c.scratchMove(-0.5 * sr, 0)], [16, (c) => { c2 = c; return c.scratchUp(); }]]);
  // find where it's back to normal playback: output matches x at a fixed offset for 0.5 s
  const t0 = Math.floor(16.4 * sr), lag = c.lag;
  let same = true;
  for (let t = 0; t < 0.5 * sr; t += 11) if (Math.abs(out[t0 + t] - x[t0 + t - lag]) > 1e-6) { same = false; break; }
  check("let go and it's back to playing the song normally within 0.4 s", same, `${(lag / sr).toFixed(2)} s behind`);
  check("and you're behind the song by the time you pulled it back and held it", lag / sr > 1.2 && lag / sr < 1.7, `${(lag / sr).toFixed(2)} s`);
}
// 4. fling forward past the newest audio: reports how far, for skipping through the song
{
  const { log } = run([[15, (c) => c.scratchDown()], [15.2, (c) => c.scratchMove(6 * sr)], [15.25, (c) => c.scratchUp()]]);
  check("spinning it way forward reports the skip", log[2] / sr > 4 && log[2] / sr < 6.5, `${(log[2] / sr).toFixed(2)} s`);
}
// 5. chops keep working after scratching
{
  const { c } = run([[12, (c) => c.scratchDown()], [12.3, (c) => c.scratchUp()], [14, (c) => c.trigger("repeatBeat")]]);
  check("live chops still work after a scratch", c.history.length === 1 && c.history[0].played && c.history[0].played.length === 1);
}
// 6. feels like a real record: the speed follows your finger's speed, gliding, even when the screen only reports
//    the finger every 1/60 s (web) or the audio only hears about it every ~90 ms (iPhone)
for (const [label, block, every] of [["web", 128, 1 / 60], ["iPhone", 4096, 1 / 60]]) {
  const c = new Chopper(sr, 5);
  const out = new Float32Array(x.length);
  const t0 = 12, dur = 2, fHz = 1.5, amp = 0.3;            // back and forth 1.5 times a second, ±0.3 s of song
  const finger = (t) => -amp * sr * Math.sin(2 * Math.PI * fHz * t);                  // offset (samples): pull back first
  const fingerSpeed = (t) => -amp * 2 * Math.PI * fHz * Math.cos(2 * Math.PI * fHz * t);  // playing speeds
  let nextMsg = t0, down = false, up = false;
  const pending = [];
  for (let i = 0; i < x.length; i += block) {
    const now = i / sr;
    // the screen reports the finger every `every` seconds; the audio picks reports up at the start of each block
    while (nextMsg <= now && nextMsg < t0 + dur) { pending.push([nextMsg - t0]); nextMsg += every; }
    if (!down && now >= t0) { c.scratchDown(); c.trace = []; c.trace.start = i; down = true; }
    if (down && !up) for (const [tt] of pending.splice(0)) c.scratchMove(finger(tt), fingerSpeed(tt));
    if (down && !up && now >= t0 + dur) { c.trace.done = c.trace.length; c.scratchUp(); up = true; }
    const a = Float32Array.from(x.subarray(i, i + block));
    c.process([a], a.length, "live");
    out.set(a, i);
  }
  const tr = c.trace.slice(0, c.trace.done), start = c.trace.start;
  // compare with the finger's speed (skip the first 0.15 s while it catches up), at the delay that fits best
  // (the screen and audio blocks add some), and report that delay
  const score = (lagS) => {
    let err = 0, n = 0, stalls = 0, moving = 0;
    for (let k = Math.floor(0.15 * sr); k < tr.length; k += 32) {
      const want = fingerSpeed((start + k) / sr - t0 - lagS);
      err += Math.abs(tr[k] - want); n++;
      if (Math.abs(want) > 0.6) { moving++; if (Math.abs(tr[k]) < 0.15) stalls++; }
    }
    return { meanErr: err / n, stalls, moving, lagS };
  };
  let best = score(0);
  for (let ms = 5; ms <= 150; ms += 5) { const r = score(ms / 1000); if (r.meanErr < best.meanErr) best = r; }
  let jerk = 0;
  for (let k = 1; k < tr.length; k++) jerk = Math.max(jerk, Math.abs(tr[k] - tr[k - 1]));
  const { meanErr, stalls, moving } = best;
  check(`${label}: it reacts quickly`, best.lagS <= (block > 1000 ? 0.13 : 0.06), `${Math.round(best.lagS * 1000)} ms behind your finger`);
  check(`${label}: the record's speed follows your finger's speed`, meanErr < 0.3, `average off by ${meanErr.toFixed(2)}x speed`);
  // (an iPhone only hears about your finger every ~90 ms, so right at a turnaround it can briefly lag)
  check(`${label}: no stop-start while your finger is moving`, stalls <= (block > 1000 ? moving * 0.02 : 0), `${stalls}/${moving} moments`);
  check(`${label}: speed glides (no sudden jumps)`, jerk < 0.01, `biggest change ${jerk.toFixed(4)} per sample`);
}

console.log(`\n${pass} passed, ${fail} failed`);
if (fail) process.exitCode = 1;
