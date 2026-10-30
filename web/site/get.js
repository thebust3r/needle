/* Platter web: find new music (songs or albums) and download it to the NAS through the helper. */
"use strict";

const getMusic = (() => {
  const ACTIVE = ["queued", "searching", "downloading", "importing", "requesting", "album"];
  const helper = (...a) => importer.helper(...a);
  let results = [];          // what the list is showing (songs), for the buttons
  let pollTimer = null;

  const art = (url) => url ? `<img class="art" loading="lazy" src="${esc(url)}" alt="" referrerpolicy="no-referrer" onerror="this.removeAttribute('src');this.classList.add('ph')">` : `<span class="art ph">${icon("wave")}</span>`;
  const who = (t) => (t.artists || []).join(", ");

  function songRow(t, k) {
    const have = !!t.songId;
    return `<div class="row get-row" data-k="${k}">
      ${art(t.cover)}
      <div class="meta"><b>${esc(t.title)}</b><span>${esc(who(t))}${t.album ? ` · ${esc(t.album)}` : ""}</span></div>
      <span class="dur">${fmt(t.duration)}</span>
      ${have ? `<button class="get-btn have" data-own="${k}" aria-label="In your library: play">${icon("check")}</button>`
             : `<button class="get-btn" data-get="${k}" aria-label="Download">${icon("download")}</button>`}
    </div>`;
  }

  async function playOwned(t) {
    try {
      const r = await api("getSong", { id: t.songId });
      player.play([toTrack(r.song)]);
    } catch (e) { toast(e.message); }
  }

  /** album: {title, artist} gets the whole album as one download (Lidarr) instead of song by song. */
  async function get(tracks, btn, album) {
    if (btn) { btn.disabled = true; btn.classList.add("busy"); }
    try {
      const body = { tracks: tracks.map((t) => ({ title: t.title, artists: t.artists, duration: t.duration, album: t.album, cover: t.cover })) };
      if (album) body.album = album;
      const r = await helper("get", body);
      toast(r.lidarr ? "Lidarr is getting the whole album" : r.added ? (r.added > 1 ? `Downloading ${r.added} songs…` : "Downloading…") : "Already on the way");
      if (btn) { btn.classList.remove("busy"); btn.classList.add("sent"); btn.innerHTML = icon("check"); }
      badge();
      return true;
    } catch (e) {
      toast(e.message);
      if (btn) { btn.disabled = false; btn.classList.remove("busy"); }
      return false;
    }
  }

  /** Search box on the Search screen, "Download" mode. */
  async function search(q, box, kind, isCurrent) {
    if (!q) {
      box.innerHTML = `<div class="empty"><b>Get new music</b>Type a song, artist or album. Pick one and Platter downloads it to your NAS.</div>`;
      return;
    }
    box.innerHTML = `<p class="note">Searching…</p>`;
    try {
      if (kind === "album") {
        const r = await helper(`find?q=${encodeURIComponent(q)}&kind=album`);
        if (!isCurrent()) return;
        box.innerHTML = (r.albums || []).map((a) => `<a class="row get-row" href="#/getalbum/${esc(a.id)}">
            ${art(a.cover)}<div class="meta"><b>${esc(a.title)}</b><span>${esc(a.artist)} · ${a.type === "single" ? "Single" : a.type === "ep" ? "EP" : "Album"}${a.tracks ? ` · ${a.tracks} songs` : ""}</span></div>
            <span class="chev">${icon("chev")}</span></a>`).join("")
          || `<div class="empty"><b>No albums found</b>Try the artist's name too.</div>`;
        return;
      }
      const r = await helper(`find?q=${encodeURIComponent(q)}`);
      if (!isCurrent()) return;
      results = r.songs || [];
      box.innerHTML = results.length ? results.map(songRow).join("") : `<div class="empty"><b>Nothing found</b>Try adding the artist's name.</div>`;
      wire(box);
    } catch (e) {
      if (isCurrent()) box.innerHTML = `<div class="empty"><b>Can't search right now</b>${esc(e.message)}</div>`;
    }
  }

  function wire(box) {
    box.onclick = (e) => {
      const g = e.target.closest("[data-get]");
      if (g) { e.stopPropagation(); return get([results[+g.dataset.get]], g); }
      const p = e.target.closest("[data-own]");
      if (p) { e.stopPropagation(); return playOwned(results[+p.dataset.own]); }
      const row = e.target.closest(".get-row[data-k]");
      if (row) {
        const t = results[+row.dataset.k];
        if (t.songId) playOwned(t); else get([t], row.querySelector("[data-get]"));
      }
    };
  }

  /** One album from the catalog: its songs, which you have, and Download Album. */
  async function album(id) {
    view.innerHTML = loading();
    try {
      const a = await helper(`find/album/${encodeURIComponent(id)}`);
      results = a.tracks || [];
      const missing = results.filter((t) => !t.songId);
      view.innerHTML = `${backLink()}<div class="album-head">${a.cover ? `<img class="art" src="${esc(a.cover.replace("250x250", "500x500"))}" alt="" referrerpolicy="no-referrer">` : ""}
        <h1>${esc(a.title)}</h1><span class="by">${esc(a.artist)}</span><small>${[a.year, `${results.length} songs`].filter(Boolean).join(" · ")}</small></div>
        <div class="pill-row">${missing.length
          ? `<button class="pill primary" id="get-all">${icon("download")}Download Album</button>`
          : `<span class="pill" style="pointer-events:none">${icon("check")}All in your library</span>`}</div>
        <div id="get-list" style="margin-top:14px">${results.map(songRow).join("")}</div>`;
      wire($("#get-list"));
      const all = $("#get-all");
      if (all) all.onclick = async () => {
        all.disabled = true;
        if (!(await get(results, null, { title: a.title, artist: a.artist }))) { all.disabled = false; return; }
        $("#get-list").querySelectorAll("[data-get]").forEach((b) => { b.classList.add("sent"); b.innerHTML = icon("check"); b.disabled = true; });
        all.innerHTML = `${icon("check")}On the way`;
      };
    } catch (e) { view.innerHTML = backLink() + errorBox(e); }
  }

  const label = (t) => ({
    found: t.note === "Already in your library" ? "Already had it" : "Added",
    queued: "Waiting…", searching: "Searching…",
    downloading: t.note && t.note.startsWith("Waiting") ? "In their queue" : `Downloading ${t.progress || 0}%`,
    importing: "Adding to library…", requesting: "Asking Lidarr…", album: "Getting album…", failed: "Didn't work",
  }[t.status] ?? t.status);

  /** Downloads: everything you asked for, newest first, live. */
  async function downloads() {
    clearTimeout(pollTimer);
    const token = (downloads.token = (downloads.token || 0) + 1);
    if (!$("#dl-list")) {
      view.innerHTML = `${backLink()}<h1 class="title">Downloads</h1>
        <div class="pill-row" style="margin-bottom:10px"><a class="pill primary" href="#/search" id="dl-find">${icon("search")}Find Music</a><button class="pill" id="dl-clear">Clear Finished</button></div>
        <div id="dl-list">${loading()}</div>`;
      $("#dl-find").onclick = () => store.set("searchMode", "get");
      $("#dl-clear").onclick = async () => { try { await helper("downloads/clear", {}); downloads(); } catch (e) { toast(e.message); } };
    }
    try {
      const j = await helper("downloads");
      if (token !== downloads.token || !$("#dl-list")) return;
      const tracks = j.tracks || [];
      $("#dl-list").innerHTML = tracks.length ? tracks.map((t) => {
        const busy = ACTIVE.includes(t.status);
        return `<div class="row dl-row ${t.status}" ${t.songId ? `data-song="${esc(t.songId)}"` : ""}>
          ${art(t.cover)}
          <div class="meta"><b>${esc(t.title)}</b><span>${esc(who(t))}${(t.status === "failed" || t.status === "queued") && t.note ? ` · ${esc(t.note)}` : ""}</span>
            ${t.status === "downloading" ? `<i class="dl-bar"><i style="width:${t.progress || 0}%"></i></i>` : ""}</div>
          <span class="dl-state">${busy ? '<span class="spin"></span>' : ""}${esc(label(t))}</span>
          ${t.status === "failed" ? `<button class="get-btn" data-retry="${t.i}" aria-label="Try again">${icon("repeat")}</button>` : ""}
        </div>`;
      }).join("") : `<div class="empty"><b>Nothing yet</b>Search for a song or album and tap download.</div>`;
      $("#dl-list").onclick = async (e) => {
        const rb = e.target.closest("[data-retry]");
        if (rb) {
          const t = tracks.find((x) => x.i === +rb.dataset.retry);
          rb.disabled = true;
          try { await helper(`jobs/${j.id}/download`, { method: "song", indexes: [t.i] }); toast("Trying again"); downloads(); } catch (err) { toast(err.message); }
          return;
        }
        const row = e.target.closest("[data-song]");
        if (row) playOwned({ songId: row.dataset.song });
      };
      if (j.active) pollTimer = setTimeout(() => { if (location.hash === "#/downloads") downloads(); }, 2500);
    } catch (e) { if ($("#dl-list")) $("#dl-list").innerHTML = errorBox(e); }
  }

  /** "2 on the way" on the Search screen. */
  async function badge() {
    const el = $("#dl-badge");
    if (!el) return;
    try {
      const j = await helper("downloads");
      const busy = (j.tracks || []).filter((t) => ACTIVE.includes(t.status)).length;
      if ($("#dl-badge")) $("#dl-badge").textContent = busy ? `${busy} on the way` : "";
    } catch { /* helper not set up */ }
  }

  return { search, album, downloads, badge };
})();
window.getMusic = getMusic;

screens.getalbum = (id) => getMusic.album(id);
screens.downloads = () => getMusic.downloads();
