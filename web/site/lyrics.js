/* Synced lyrics: the current line lights up and scrolls with the song; tap a line to jump there.
   Sources, in order: Navidrome (lyrics in your files or .lrc files next to them), then LRCLIB. */
"use strict";

const lyrics = (() => {
  const panel = $("#lyrics"), body = $("#lyrics-body"), btn = $("#np-lyrics");
  let on = store.get("lyricsOn", false);
  let current = null;            // { id, synced, lines: [{t, text}], source }
  let loadingId = null, activeIndex = -1, raf = 0, userScrollUntil = 0;

  /** "[01:23.45]text" lines → [{t: seconds, text}] */
  function parseLRC(lrc) {
    const out = [];
    let offset = 0;
    for (const raw of String(lrc).split(/\r?\n/)) {
      const off = raw.match(/^\[offset:\s*([+-]?\d+)\s*\]/i);
      if (off) { offset = +off[1] / 1000; continue; }
      const stamps = [...raw.matchAll(/\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]/g)];
      if (!stamps.length) continue;
      const text = raw.replace(/\[[^\]]*\]/g, "").trim();
      for (const s of stamps) out.push({ t: +s[1] * 60 + parseFloat(s[2].replace(":", ".")), text });
    }
    out.forEach((l) => (l.t = Math.max(0, l.t - offset)));
    return out.sort((a, b) => a.t - b.t);
  }

  async function fromNavidrome(t) {
    try {
      const r = await api("getLyricsBySongId", { id: t.id });
      const list = r.lyricsList?.structuredLyrics || [];
      const synced = list.find((l) => l.synced && l.line?.length);
      if (synced) {
        const off = (synced.offset || 0) / 1000;
        return { synced: true, source: "your files", lines: synced.line.map((l) => ({ t: Math.max(0, (l.start || 0) / 1000 - off), text: l.value || "" })) };
      }
      const plain = list.find((l) => l.line?.length);
      if (plain) return { synced: false, source: "your files", lines: plain.line.map((l) => ({ t: 0, text: l.value || "" })) };
    } catch { /* older Navidrome or no lyrics */ }
    return null;
  }

  async function lrclibFetch(path) {
    for (const base of ["lrclib/api/", "https://lrclib.net/api/"]) {   // through the NAS first, then direct
      try {
        const r = await fetch(base + path);
        if (r.status === 404) return null;
        if (r.ok) return await r.json();
      } catch { /* try the next route */ }
    }
    throw new Error("unreachable");
  }

  async function fromLRCLIB(t) {
    const q = (o) => Object.entries(o).filter(([, v]) => v).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join("&");
    let hit = await lrclibFetch("get?" + q({ artist_name: t.artist, track_name: t.title, album_name: t.album, duration: Math.round(t.duration) || "" }));
    if (!hit || (!hit.syncedLyrics && !hit.plainLyrics)) {
      const results = await lrclibFetch("search?" + q({ artist_name: t.artist, track_name: t.title })) || [];
      hit = results.find((x) => x.syncedLyrics && (!t.duration || Math.abs((x.duration || 0) - t.duration) < 4))
         || results.find((x) => x.syncedLyrics) || results.find((x) => x.plainLyrics) || null;
    }
    if (!hit) return null;
    if (hit.instrumental) return { synced: false, source: "LRCLIB", lines: [], instrumental: true };
    if (hit.syncedLyrics) return { synced: true, source: "LRCLIB", lines: parseLRC(hit.syncedLyrics) };
    if (hit.plainLyrics) return { synced: false, source: "LRCLIB", lines: hit.plainLyrics.split(/\r?\n/).map((text) => ({ t: 0, text })) };
    return null;
  }

  async function load(t) {
    if (!t || t.local) { current = { id: t?.id, lines: [], none: true }; render(); return; }
    if (current?.id === t.id || loadingId === t.id) return;
    const key = "lyr." + t.id;
    const cached = store.get(key, null);
    if (cached && (!cached.none || Date.now() - cached.at < 7 * 864e5)) { current = { id: t.id, ...cached }; render(); return; }
    loadingId = t.id;
    current = { id: t.id, loading: true, lines: [] };
    render();
    let result = null, failed = false;
    try { result = (await fromNavidrome(t)) || (await fromLRCLIB(t)); }
    catch { failed = true; }
    if (loadingId !== t.id) return;             // song changed while loading
    loadingId = null;
    if (failed) { current = { id: t.id, lines: [], error: true }; render(); return; }
    current = result ? { id: t.id, ...result } : { id: t.id, lines: [], none: true };
    try { store.set(key, { ...current, id: undefined, at: Date.now() }); } catch { /* storage full */ }
    render();
  }

  function render() {
    activeIndex = -1;
    if (!current || current.loading) { body.innerHTML = `<p class="ly-note">Finding lyrics…</p>`; return; }
    if (current.error) { body.innerHTML = `<p class="ly-note">Couldn't reach the lyrics service. Check your connection.</p>`; return; }
    if (current.instrumental) { body.innerHTML = `<p class="ly-note">Instrumental. No lyrics to show.</p>`; return; }
    if (current.none || !current.lines.length) { body.innerHTML = `<p class="ly-note">No lyrics found for this song.</p>`; return; }
    body.innerHTML = current.lines.map((l, i) =>
      `<p class="ly-line ${current.synced ? "" : "static"} ${l.text ? "" : "gap"}" data-i="${i}">${l.text ? esc(l.text) : "♪"}</p>`).join("")
      + `<p class="ly-source">${current.synced ? "Synced lyrics" : "Lyrics"} from ${esc(current.source)}</p>`;
    body.scrollTop = 0;
  }

  function tick() {
    raf = requestAnimationFrame(tick);
    if (!on || !current?.synced || !current.lines.length || $("#np").hidden) return;
    const now = player.time() + 0.15;            // tiny lead so the line lights as it's sung
    let i = -1, lo = 0, hi = current.lines.length - 1;
    while (lo <= hi) { const m = (lo + hi) >> 1; if (current.lines[m].t <= now) { i = m; lo = m + 1; } else hi = m - 1; }
    if (i === activeIndex) return;
    const els = body.children;
    if (activeIndex >= 0 && els[activeIndex]) els[activeIndex].classList.remove("now");
    for (let k = 0; k < current.lines.length; k++) els[k].classList.toggle("past", k < i);
    activeIndex = i;
    if (i >= 0 && els[i]) {
      els[i].classList.add("now");
      if (Date.now() > userScrollUntil) {
        const target = els[i].offsetTop - body.clientHeight * 0.32;
        body.scrollTo({ top: Math.max(0, target), behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
      }
    }
  }

  function apply() {
    panel.hidden = !on;
    $("#np-stage").hidden = on;
    btn.classList.toggle("on", on);
    btn.setAttribute("aria-pressed", on);
    if (on) {
      load(player.current);
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(tick);
      if (window.Viz) Viz.stop();
      document.body.classList.remove("viz-active");
    } else {
      cancelAnimationFrame(raf);
      if (window.vizUI) vizUI.refresh();
    }
  }

  btn.onclick = () => { on = !on; store.set("lyricsOn", on); apply(); };
  body.addEventListener("click", (e) => {
    const line = e.target.closest(".ly-line");
    if (!line || !current?.synced) return;
    player.seek(current.lines[+line.dataset.i].t);
    userScrollUntil = 0;
  });
  ["wheel", "touchmove"].forEach((ev) => body.addEventListener(ev, () => { userScrollUntil = Date.now() + 3500; }, { passive: true }));

  return {
    parseLRC,
    trackChanged(t) { current = null; loadingId = null; if (on) load(t); },
    npOpened() { if (on) apply(); else { panel.hidden = true; $("#np-stage").hidden = false; } },
    npClosed() { cancelAnimationFrame(raf); },
    get on() { return on; },
    get current() { return current; },
  };
})();
window.lyrics = lyrics;
