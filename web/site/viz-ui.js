/* Visualizer controls: tap the album art to flip it into the visualizer, tap again to flip back. */
"use strict";
window.Viz = Viz;

const vizUI = (() => {
  const stage = $("#np-stage"), small = $("#viz"), big = $("#viz-big"), full = $("#vizfull");
  let on = store.get("vizOn", false);
  let hintTimer = 0, idleTimer = 0;
  let downX = 0, downY = 0, moved = false;

  const label = () => (Viz.auto ? `Auto · ${Viz.mode.name}` : Viz.mode.name);
  function refreshLabels() {
    $("#viz-mode").textContent = label();
    $("#vf-mode").textContent = label();
  }

  /** Taps cycle: Auto → each style → back to Auto. */
  function cycleMode() {
    if (Viz.auto) { Viz.setAuto(false); Viz.setMode(0); }
    else if (Viz.mode === Viz.MODES[Viz.MODES.length - 1]) { Viz.setAuto(true); }
    else Viz.next();
    refreshLabels();
  }

  function npVisible() { return !$("#np").hidden; }

  function apply() {
    if (window.lyrics && lyrics.on) { Viz.stop(); return; }   // lyrics are showing instead of the art
    stage.classList.toggle("viz-on", on);
    stage.setAttribute("aria-label", on ? "Visualizer. Tap to show the album art" : "Album art. Tap to show the visualizer");
    if (on && npVisible() && full.hidden) { Viz.attach(small); Viz.start(); }
    else if (full.hidden) Viz.stop();
    document.body.classList.toggle("viz-active", on && npVisible());
    refreshLabels();
    updateHint();
  }

  function updateHint() {
    clearInterval(hintTimer);
    const check = () => {
      const show = on && npVisible() && player.playing && !eq.enabled;
      $("#viz-hint").hidden = !show;
    };
    check();
    if (on) hintTimer = setInterval(check, 1000);
  }

  function toggle() {
    on = !on;
    store.set("vizOn", on);
    apply();
  }

  function openFull() {
    full.hidden = false;
    document.body.classList.add("viz-active", "viz-full");
    const t = player.current;
    $("#vf-title").textContent = t ? t.title : "";
    $("#vf-artist").textContent = t ? t.artist : "";
    Viz.attach(big);
    Viz.start();
    wakeControls();
    refreshLabels();
  }
  function closeFull() {
    full.hidden = true;
    document.body.classList.remove("viz-full");
    document.body.classList.toggle("viz-active", on && npVisible());
    clearTimeout(idleTimer);
    full.classList.remove("idle");
    if (on && npVisible()) { Viz.attach(small); Viz.start(); } else Viz.stop();
  }
  function wakeControls() {
    full.classList.remove("idle");
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => full.classList.add("idle"), 2500);
  }

  // tap vs swipe on the art: swipes skip songs (handled in app.js), taps flip
  stage.addEventListener("pointerdown", (e) => { downX = e.clientX; downY = e.clientY; moved = false; });
  stage.addEventListener("pointermove", (e) => { if (Math.abs(e.clientX - downX) + Math.abs(e.clientY - downY) > 12) moved = true; });
  stage.addEventListener("click", (e) => {
    if (e.target.closest(".viz-ui") || moved) return;
    toggle();
  });
  stage.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggle(); } });
  $("#viz-mode").onclick = (e) => { e.stopPropagation(); cycleMode(); };
  $("#viz-full").onclick = (e) => { e.stopPropagation(); openFull(); };

  // full screen: tap shows controls, swipe sideways changes style
  $("#vf-close").onclick = (e) => { e.stopPropagation(); closeFull(); };
  $("#vf-mode").onclick = (e) => { e.stopPropagation(); cycleMode(); wakeControls(); };
  let fx = 0;
  full.addEventListener("pointerdown", (e) => { fx = e.clientX; });
  full.addEventListener("pointerup", (e) => {
    const dx = e.clientX - fx;
    if (Math.abs(dx) > 60) { Viz.setAuto(false); Viz.next(dx < 0 ? 1 : -1); refreshLabels(); }
    wakeControls();
  });
  document.addEventListener("keydown", (e) => {
    if (full.hidden) return;
    const handled = ["Escape", "ArrowRight", "ArrowLeft", " "].includes(e.key);
    if (handled) { e.preventDefault(); e.stopPropagation(); }   // full screen owns these keys while it's open
    if (e.key === "Escape") closeFull();
    if (e.key === "ArrowRight" || e.key === "ArrowLeft") { Viz.setAuto(false); Viz.next(e.key === "ArrowRight" ? 1 : -1); refreshLabels(); }
    if (e.key === " ") player.toggle();
    wakeControls();
  }, true);

  Viz.onModeChange = refreshLabels;
  document.addEventListener("visibilitychange", () => { if (!document.hidden && Viz.running) Viz.start(); });

  refreshLabels();
  return {
    npOpened() { apply(); },
    npClosed() { if (full.hidden) Viz.stop(); clearInterval(hintTimer); document.body.classList.remove("viz-active"); },
    toggle, openFull, closeFull,
    get on() { return on; },
  };
})();
window.vizUI = vizUI;
