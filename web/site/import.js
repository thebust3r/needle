/* Needle web: import a Spotify playlist (or a pasted song list) into a Navidrome playlist,
   and fetch missing songs through the helper on the NAS (slskd or Lidarr). */
"use strict";

const importer = (() => {
  const ACTIVE = ["queued", "searching", "downloading", "importing", "requesting", "album"];
  let pollTimer = null;
  let status = null;

  async function helper(path, body, method) {
    let r;
    try {
      r = await fetch(`helper/${path}${path.includes("?") ? "&" : "?"}${auth()}`, {
        method: method || (body ? "POST" : "GET"),
        headers: body ? { "Content-Type": "application/json" } : {},
        body: body ? JSON.stringify(body) : undefined,
      });
    } catch { throw new Error("Can't reach the NAS."); }
    const type = r.headers.get("Content-Type") || "";
    if (!type.includes("json")) throw new Error("The import helper isn't running yet. Update the Platter project on the NAS (the one called needle) with the new compose file (see the README).");
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || `Error ${r.status}`);
    return j;
  }

  function stopPolling() { clearTimeout(pollTimer); pollTimer = null; }

  const label = (t) => ({
    found: t.note ? "Added" : "",
    missing: "Missing",
    matching: "Checking…",
    queued: "Waiting…",
    searching: "Searching…",
    downloading: t.note && t.note.startsWith("Waiting") ? "In their queue" : `Downloading ${t.progress || 0}%`,
    importing: "Adding…",
    requesting: "Asking Lidarr…",
    album: "Getting album…",
    failed: "Not found",
  }[t.status] ?? t.status);

  function summary(j) {
    const c = j.counts || {};
    const total = (j.tracks ? j.tracks.length : Object.values(c).reduce((a, b) => a + b, 0)) || j.progress?.total || 0;
    if (j.state === "error") return j.error || "Didn't work";
    if (j.state === "reading") return "Reading the playlist…";
    if (j.state === "matching") return `Checking your library… ${j.progress.done} of ${j.progress.total}`;
    const busy = ACTIVE.reduce((n, k) => n + (c[k] || 0), 0);
    return `${j.found} of ${total} in your library` + (busy ? ` · ${busy} on the way` : "") + (c.failed ? ` · ${c.failed} not found` : "");
  }

  async function home() {
    stopPolling();
    view.innerHTML = `${backLink()}<h1 class="title">Import Playlist</h1>
      <p class="note" style="margin-top:-6px">Paste a Spotify playlist or album link. Platter finds the songs you already have and makes a playlist in the same order, then can download the rest.</p>
      <div class="form imp-form">
        <label><span>Spotify link or song list</span><textarea id="imp-src" rows="4" placeholder="https://open.spotify.com/playlist/…&#10;&#10;or one song per line:  Artist - Song" autocapitalize="off" autocorrect="off" spellcheck="false"></textarea></label>
        <label><span>Playlist name (optional)</span><input id="imp-name" placeholder="Uses the Spotify name"></label>
      </div>
      <div class="pill-row" style="margin-top:14px"><button class="pill primary" id="imp-go">${icon("import")}Import</button>
        <button class="pill" id="imp-paste">Paste</button></div>
      <p class="note bad" id="imp-err"></p>
      <div class="section"><div class="section-head"><h2 class="h2">Recent Imports</h2></div><div id="imp-list">${loading()}</div></div>`;
    const token = routeToken;
    $("#imp-paste").onclick = async () => {
      try { $("#imp-src").value = await navigator.clipboard.readText(); } catch { $("#imp-src").focus(); toast("Long-press the box and tap Paste"); }
    };
    $("#imp-go").onclick = async () => {
      const source = $("#imp-src").value.trim();
      const err = $("#imp-err");
      if (!source) { err.textContent = "Paste a Spotify link or a list of songs first."; return; }
      const btn = $("#imp-go");
      btn.disabled = true; err.textContent = "";
      try {
        const j = await helper("import", { source, name: $("#imp-name").value.trim() });
        location.hash = `#/import/${j.id}`;
      } catch (e) { err.textContent = e.message; btn.disabled = false; }
    };
    try {
      const { jobs } = await helper("jobs");
      if (token !== routeToken) return;
      $("#imp-list").innerHTML = jobs.length ? jobs.map((j) => `<a class="row" href="#/import/${esc(j.id)}">
          <span class="imp-ic ${j.state === "error" ? "bad" : j.active ? "busy" : ""}">${icon(j.state === "error" ? "x" : "playlist")}</span>
          <div class="meta"><b>${esc(j.name || "Import")}</b><span>${esc(summary(j))}</span></div>${icon("chev")}</a>`).join("")
        : `<div class="empty" style="padding:28px 32px"><b>Nothing imported yet</b>In Spotify, tap ••• on a playlist › Share › Copy link, then paste it above.</div>`;
    } catch (e) {
      if (token === routeToken) $("#imp-list").innerHTML = `<div class="empty" style="padding:28px 32px"><b>Import isn't ready</b>${esc(e.message)}</div>`;
    }
  }

  async function show(id) {
    stopPolling();
    const token = routeToken;
    view.innerHTML = `${backLink()}<div id="imp">${loading()}</div>`;
    if (!status) helper("status").then((s) => { status = s; }).catch(() => {});
    let lastSig = "";
    const tick = async () => {
      if (token !== routeToken) return;
      let j;
      try { j = await helper(`jobs/${id}`); } catch (e) {
        if (token === routeToken && !lastSig) $("#imp").innerHTML = errorBox(e);
        pollTimer = setTimeout(tick, 5000);
        return;
      }
      if (token !== routeToken) return;
      const sig = JSON.stringify([j.state, j.progress, j.tracks.map((t) => [t.status, t.progress, t.note]), !!status]);
      if (sig !== lastSig) { lastSig = sig; render(j); }
      if (["reading", "matching"].includes(j.state) || j.active) pollTimer = setTimeout(tick, j.state === "matching" ? 700 : 2000);
    };
    await tick();
  }

  function render(j) {
    const box = $("#imp");
    if (!box) return;
    const missing = j.tracks.filter((t) => t.status === "missing" || t.status === "failed");
    const working = ["reading", "matching"].includes(j.state);
    const total = j.tracks.length || j.progress.total;
    const pct = working ? (j.progress.total ? j.progress.done / j.progress.total : 0) : (total ? j.found / total : 0);
    const canSong = status ? status.soulseek : true, canAlbum = status ? status.lidarr : true;
    box.innerHTML = `<h1 class="title" style="margin-bottom:6px">${esc(j.name || "Importing…")}</h1>
      <p class="note ${j.state === "error" ? "bad" : ""}" style="margin-top:0" id="imp-sum">${esc(summary(j))}</p>
      ${j.state !== "error" ? `<div class="imp-bar"><i style="width:${Math.round(pct * 100)}%"></i></div>` : ""}
      ${j.note ? `<p class="note">${esc(j.note)}</p>` : ""}
      ${j.playlistId && !working ? `<div class="pill-row" style="margin-top:16px"><button class="pill primary" id="imp-play">${icon("play")}Play</button>
          <a class="pill" href="#/playlist/${esc(j.playlistId)}">${icon("playlist")}Open Playlist</a></div>` : ""}
      ${missing.length && !working ? `<div class="imp-card">
          <b>${missing.length} song${missing.length === 1 ? " isn't" : "s aren't"} in your library</b>
          <span>Download ${missing.length === 1 ? "it" : "them"} and Platter adds ${missing.length === 1 ? "it" : "them"} to this playlist in the right spot${missing.length === 1 ? "" : "s"}.</span>
          <div class="imp-choices">
            <button class="pill primary" data-get="song" ${canSong ? "" : "disabled"}>Just the Songs<small>Soulseek</small></button>
            <button class="pill" data-get="album" ${canAlbum ? "" : "disabled"}>Whole Albums<small>Lidarr</small></button>
          </div>
          ${!canSong || !canAlbum ? `<span class="small">${!canSong ? "Soulseek" : "Lidarr"} isn't connected to the helper yet. Add its address and API key in the compose file.</span>` : ""}
        </div>` : ""}
      ${j.tracks.length ? `<div class="section"><div class="section-head"><h2 class="h2">Songs</h2>
          ${missing.length && !working ? `<button class="chip ${filterMissing ? "on" : ""}" id="imp-filter">Missing only</button>` : ""}</div>
        ${j.tracks.filter((t) => !filterMissing || t.status !== "found").map((t) => `<div class="row imp-row st-${t.status}">
          <span class="num">${t.i + 1}</span>
          <div class="meta"><b>${esc(t.title)}</b><span>${esc((t.artists || [])[0] || "")}${t.note && t.status !== "found" ? " · " + esc(t.note) : ""}</span></div>
          ${t.status === "found" ? `<span class="st ok">${t.note ? esc(label(t)) + " " : ""}${icon("check")}</span>` : `<span class="st">${esc(label(t))}</span>`}
          ${t.status === "failed" ? `<button class="more" data-retry="${t.i}" aria-label="Try again">${icon("repeat")}</button>` : ""}
        </div>`).join("")}</div>` : ""}
      ${!working ? `<p class="note" style="text-align:center;margin-top:26px"><a href="#/import" id="imp-del" style="color:var(--ter)">Remove from Recent Imports</a></p>` : ""}`;
    const play = $("#imp-play");
    if (play) play.onclick = async () => {
      try { const p = await lib.playlist(j.playlistId); player.play((p.entry || []).map(toTrack)); } catch (e) { toast(e.message); }
    };
    $$("[data-get]", box).forEach((b) => (b.onclick = () => download(j, b.dataset.get, missing.map((t) => t.i))));
    $$("[data-retry]", box).forEach((b) => (b.onclick = () => {
      const t = j.tracks[+b.dataset.retry];
      showChoice(j, t);
    }));
    const f = $("#imp-filter");
    if (f) f.onclick = () => { filterMissing = !filterMissing; render(j); };
    const del = $("#imp-del");
    if (del) del.onclick = async (e) => { e.preventDefault(); try { await helper(`jobs/${j.id}`, null, "DELETE"); } catch { /* already gone */ } location.hash = "#/import"; };
  }
  let filterMissing = false;

  function showChoice(j, t) {
    const m = $("#menu");
    m.innerHTML = `<div class="panel"><p>Try again: ${esc(t.title)}</p>
      <button data-a="song">${icon("import")}Just the Song (Soulseek)</button>
      <button data-a="album">${icon("album")}Whole Album (Lidarr)</button></div>`;
    m.hidden = false;
    m.onclick = (e) => {
      const a = e.target.closest("button")?.dataset.a;
      m.hidden = true;
      if (a) download(j, a, [t.i]);
    };
  }

  async function download(j, method, indexes) {
    try {
      await helper(`jobs/${j.id}/download`, { method, indexes });
      toast(method === "song" ? "Searching Soulseek…" : "Asking Lidarr for the albums…");
      show(j.id);
    } catch (e) { toast(e.message); }
  }

  return { home, show, stopPolling, helper };
})();
window.importer = importer;

screens.import = (id) => (id ? importer.show(id) : importer.home());
