/* Needle web: the turntable. In Live chop mode the cover turns into a record (the art is the label).
   Drag around it to scratch, hold it to stop it, let go and the motor brings it back up to speed.
   Spin it hard and it coasts; spin it far enough and it skips through the song. Same as the app. */
"use strict";
const turntable = (() => {
  const SEC_PER_REV = 1.8;              // 33⅓ rpm: one turn of the record is 1.8 s of song (as you hear it)
  const RPM_DEG = 360 * 33.333 / 60;    // degrees per second when it's playing
  let el, disc, label, stage, on = false, raf = 0, last = 0;
  let angle = 0, touching = false, coasting = false;
  let grabA = 0, prevA = 0, turned = 0, sent = 0, sentSpeed = 0, pending = false, lastMove = 0;
  let samples = [];                      // recent [time, turned] for the fling speed
  let vel = 0;                           // coasting speed, degrees per second

  function init() {
    el = $("#vinyl"); disc = $(".vinyl-disc", el); label = $(".vinyl-label", el); stage = $("#np-stage");
    el.addEventListener("pointerdown", down);
    el.addEventListener("pointermove", move);
    el.addEventListener("pointerup", up);
    el.addEventListener("pointercancel", up);
    el.addEventListener("contextmenu", (e) => e.preventDefault());
    el.addEventListener("click", (e) => e.stopPropagation());       // the record isn't the visualizer button
  }
  function show(yes) {
    if (!el) init();
    on = yes;
    el.hidden = !yes;
    stage.classList.toggle("turntable", yes);
    if (yes) { setLabel(); if (!raf) { last = performance.now(); raf = requestAnimationFrame(frame); } }
  }
  function setLabel() {
    const art = $(".np-art", stage);
    if (art && label.src !== art.src) label.src = art.src;
  }
  function centerAngle(e) {
    const r = el.getBoundingClientRect();
    return Math.atan2(e.clientY - (r.top + r.height / 2), e.clientX - (r.left + r.width / 2)) * 180 / Math.PI;
  }
  const wrap = (d) => (d > 180 ? d - 360 : d < -180 ? d + 360 : d);

  function down(e) {
    e.preventDefault();
    try { el.setPointerCapture(e.pointerId); } catch {}
    audio.ensure();
    touching = true; coasting = false;
    grabA = prevA = centerAngle(e); turned = 0; sent = 0; sentSpeed = 0; lastMove = 0; samples = [[performance.now(), 0]];
    audio.scratch("down");
    el.classList.add("held");
    if (navigator.vibrate) navigator.vibrate(6);
  }
  function move(e) {
    if (!touching) return;
    const a = centerAngle(e), d = wrap(a - prevA);
    prevA = a; turned += d; angle += d;
    const now = performance.now();
    samples.push([now, turned]); while (samples.length > 2 && now - samples[0][0] > 90) samples.shift();
    lastMove = now;
    send();
  }
  /** How fast the record is turning right now, in playing speeds (1 = normal, 0 = still, negative = backwards). */
  function handSpeed() {
    if (coasting) return vel / (360 / SEC_PER_REV);
    const now = performance.now();
    if (now - lastMove > 45) return 0;                   // finger resting on the record: it's stopped
    const recent = samples.filter(([t]) => now - t <= 50);
    if (recent.length < 2) return sentSpeed;
    const [t0, a0] = recent[0], [t1, a1] = recent[recent.length - 1];
    return t1 > t0 ? (a1 - a0) / ((t1 - t0) / 1000) / (360 / SEC_PER_REV) : sentSpeed;
  }
  function send() {
    if (pending) return;
    pending = true;
    requestAnimationFrame(() => {
      pending = false;
      const sp = handSpeed();
      if (turned !== sent || Math.abs(sp - sentSpeed) > 0.01) { sent = turned; sentSpeed = sp; audio.scratch("move", turned / 360 * SEC_PER_REV, sp); }
    });
  }
  function up() {
    if (!touching) return;
    touching = false;
    el.classList.remove("held");
    const [t0, a0] = samples[0], [t1, a1] = samples[samples.length - 1];
    const speed = t1 > t0 ? (a1 - a0) / ((t1 - t0) / 1000) : 0;       // degrees per second
    if (Math.abs(speed) > RPM_DEG * 2.5) { coasting = true; vel = speed; return; }   // a fling: let it coast
    letGo();
  }
  function letGo() { coasting = false; audio.scratch("up"); }

  /** The chopper says how far past the ends of what it has you spun it: skip the song by that much. */
  function scratched(seconds) {
    if (Math.abs(seconds) < 0.3) return;
    player.seek(player.time() + seconds * screw.rate);
    toast(seconds > 0 ? `Skipped ahead ${Math.round(seconds * screw.rate)} s` : `Back ${Math.round(-seconds * screw.rate)} s`);
  }

  function frame(t) {
    raf = 0;
    if (!on) return;
    const dt = Math.min(0.05, (t - last) / 1000); last = t;
    if (touching) send();                                      // keeps the speed current (drops to 0 when your finger rests)
    if (coasting) {
      vel *= Math.exp(-dt / 0.7);                              // the platter slowing down under its own weight
      const d = vel * dt; turned += d; angle += d; send();
      if (Math.abs(vel) < RPM_DEG * 1.2) letGo();
    } else if (!touching && player.playing && !matchMedia("(prefers-reduced-motion: reduce)").matches) {
      angle += RPM_DEG * screw.rate * dt;                      // spinning along with the music
    }
    disc.style.transform = `rotate(${angle % 360}deg)`;
    if (Math.random() < 0.02) setLabel();
    raf = requestAnimationFrame(frame);
  }
  return { show, scratched, get active() { return touching || coasting; } };
})();
