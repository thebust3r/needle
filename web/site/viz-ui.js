/* Visualizer controls: tap the album art to flip it into the visualizer, tap again to flip back. */
"use strict";
window.Viz = Viz;

const vizUI = (() => {
  const stage = $("#np-stage"), small = $("#viz"), big = $("#viz-big"), full = $("#vizfull");
  let on = false;
  let idleTimer = 0;
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
    player.reroute();     // the visualizer listens through Web Audio, so it reacts even with the EQ off
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
    Viz.attach(big, { touch: true });
    Viz.start();
    wakeControls();
    refreshLabels();
    const tip = $("#vf-tip");
    tip.classList.remove("gone");
    setTimeout(() => tip.classList.add("gone"), 3500);
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
    if (stage.classList.contains("turntable")) return;     // Live mode: the cover is a record
    if (e.target.closest(".viz-ui") || moved) return;
    toggle();
  });
  stage.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggle(); } });
  $("#viz-mode").onclick = (e) => { e.stopPropagation(); cycleMode(); };
  $("#viz-full").onclick = (e) => { e.stopPropagation(); openFull(); };

  // full screen: drag swirls the picture and taps make a burst (in viz.js); any touch shows the controls
  $("#vf-close").onclick = (e) => { e.stopPropagation(); closeFull(); };
  $("#vf-mode").onclick = (e) => { e.stopPropagation(); cycleMode(); wakeControls(); };
  $("#vf-prev").onclick = (e) => { e.stopPropagation(); Viz.setAuto(false); Viz.next(-1); refreshLabels(); wakeControls(); };
  $("#vf-next").onclick = (e) => { e.stopPropagation(); Viz.setAuto(false); Viz.next(1); refreshLabels(); wakeControls(); };
  $("#vf-custom").onclick = (e) => { e.stopPropagation(); openCustomize(); };
  $("#viz-custom").onclick = (e) => { e.stopPropagation(); openCustomize(); };
  full.addEventListener("pointerdown", wakeControls);

  /** Styles, colors, reactivity, trails, speed, mirror: changes show live behind the panel. */
  function openCustomize() {
    const m = $("#menu"), st = Viz.settings;
    const render = () => {
      m.innerHTML = `<div class="panel viz-panel">
        <h3>Visualizer</h3>
        <small>STYLE</small>
        <div class="vp-styles"><button data-style="auto" class="${Viz.auto ? "on" : ""}">Auto</button>${Viz.MODES.map((md, i) =>
          `<button data-style="${i}" class="${!Viz.auto && Viz.mode === md ? "on" : ""}">${md.name}</button>`).join("")}</div>
        <small>COLORS</small>
        <div class="vp-themes">${Object.entries(Viz.THEMES).map(([k, t]) => `<button data-theme="${k}" class="${st.theme === k ? "on" : ""}">
          <i style="background:${t.c ? `linear-gradient(90deg,${t.c.map((c) => `rgb(${c.map((v) => Math.round(v * 255)).join(",")})`).join(",")})` : "conic-gradient(from 0deg, var(--np-accent, #6ee8d9), #ff5ca8, #61adff, var(--np-accent, #6ee8d9))"}"></i>${t.name}</button>`).join("")}</div>
        ${slider("intensity", "Reactivity", 0.4, 2, 0.05, st.intensity, (v) => v < 0.8 ? "Chill" : v < 1.3 ? "Normal" : v < 1.7 ? "Hype" : "Max")}
        ${slider("trails", "Trails", 0, 1, 0.02, st.trails, (v) => v < 0.3 ? "Short" : v < 0.75 ? "Medium" : "Long")}
        ${slider("speed", "Speed", 0.4, 2, 0.05, st.speed, (v) => v < 0.8 ? "Slow" : v < 1.3 ? "Normal" : "Fast")}
        <label class="vp-toggle"><span>Kaleidoscope mirror</span><input type="checkbox" id="vp-mirror" ${st.mirror ? "checked" : ""}></label>
        <div class="vp-actions"><button class="vp-reset">Reset</button><button class="vp-done">Done</button></div></div>`;
      $$(".viz-panel input[type=range]", m).forEach((r) => (r.oninput = () => {
        Viz.set(r.dataset.key, +r.value);
        r.closest(".vp-slider").querySelector("em").textContent = r.dataset.words ? words[r.dataset.key](+r.value) : "";
      }));
      $("#vp-mirror").onchange = (e) => Viz.set("mirror", e.target.checked);
    };
    const words = {};
    function slider(key, name, min, max, step, val, word) {
      words[key] = word;
      return `<div class="vp-slider"><span>${name}<em>${word(val)}</em></span>
        <input type="range" data-key="${key}" data-words="1" min="${min}" max="${max}" step="${step}" value="${val}" aria-label="${name}"></div>`;
    }
    render();
    m.hidden = false;
    m.classList.add("over-viz");
    m.onclick = (e) => {
      if (e.target === m || e.target.closest(".vp-done")) { m.hidden = true; m.classList.remove("over-viz"); return; }
      const b = e.target.closest("[data-style], [data-theme], .vp-reset");
      if (!b) return;
      if (b.dataset.style === "auto") Viz.setAuto(true);
      else if (b.dataset.style != null) { Viz.setAuto(false); Viz.setMode(+b.dataset.style); }
      else if (b.dataset.theme) Viz.set("theme", b.dataset.theme);
      else Viz.resetSettings();
      refreshLabels();
      render();
    };
  }

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
    npOpened() { on = false; apply(); },   // Now Playing always opens on the album art
    refresh() { apply(); },                // lyrics closed: show whatever was there before
    npClosed() { if (full.hidden) Viz.stop(); document.body.classList.remove("viz-active"); },
    toggle, openFull, closeFull, openCustomize,
    get on() { return on; },
  };
})();
window.vizUI = vizUI;
