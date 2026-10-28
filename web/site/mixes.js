/* Needle web: listening history, Continue Listening, daily mixes, weather, accent color and the new Home.
   Same rules as the iPhone app (ios/Needle/Core/Mixes.swift). */
"use strict";

/* ---------------- listening history (kept in this browser) ---------------- */
const plays = {
  list: store.get("history", []),
  startedAt: 0,
  started(t) {
    if (!t || t.local) return;
    const now = Date.now(), last = this.list[this.list.length - 1];
    if (last && last.id === t.id && now - last.at < 20000) return;
    if (last && last.listened == null && this.startedAt) last.listened = Math.min(last.duration, (now - this.startedAt) / 1000);
    this.list.push({ id: t.id, title: t.title, artist: t.artist, album: t.album, albumId: t.albumId, coverArt: t.coverArt,
                     duration: t.duration || 0, at: now });
    this.startedAt = now;
    if (this.list.length > 3000) this.list.splice(0, this.list.length - 3000);
    store.set("history", this.list);
  },
};
const skipped = (r) => (r.listened ?? r.duration) < Math.min(30, r.duration * 0.5);
const recSong = (r) => ({ id: r.id, title: r.title, artist: r.artist, album: r.album, albumId: r.albumId, coverArt: r.coverArt, duration: r.duration });

/* ---------------- pick up where you left off ---------------- */
const session = {
  save() {
    const q = player.queue;
    if (!q.length || q.some((t) => t.local)) return;
    const lo = Math.max(0, player.i - 50), hi = Math.min(q.length, player.i + 250);
    store.set("session", { queue: q.slice(lo, hi), i: player.i - lo, time: player.time(), shuffled: player.shuffled });
  },
  restore() {
    const s = store.get("session", null);
    if (!s || !s.queue?.[s.i] || player.queue.length) return;
    player.queue = s.queue; player.original = s.queue.slice(); player.i = s.i; player.shuffled = !!s.shuffled;
    player.resumeAt = s.time || 0;
    ui.trackChanged();
  },
};

/* ---------------- the mixer ---------------- */
const Mixer = (() => {
  const SIZE = 30;
  const key = (s) => String(s || "").toLowerCase().trim();
  const DAY = 86400000;

  function rng(seed) {                    // mulberry32 on a hash of the seed text
    let h = 2166136261;
    for (const c of seed) h = Math.imul(h ^ c.charCodeAt(0), 16777619);
    let a = h >>> 0;
    return () => { a |= 0; a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  }
  const hue = (s) => { let h = 2166136261; for (const c of s) h = Math.imul(h ^ c.charCodeAt(0), 16777619); return ((h >>> 0) % 1000) / 1000; };
  const dayKey = (d) => `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
  const part = (h) => (h >= 5 && h < 11 ? "morning" : h >= 11 && h < 17 ? "afternoon" : h >= 17 && h < 22 ? "evening" : "lateNight");
  const partTitle = { morning: "Morning Mix", afternoon: "Afternoon Mix", evening: "Evening Mix", lateNight: "Late Night Mix" };

  function weights(lib, hist, now) {
    const w = {};
    const add = (a, v) => { if (a) w[key(a)] = (w[key(a)] || 0) + v; };
    for (const r of hist) if (now - r.at < 90 * DAY) add(r.artist, skipped(r) ? -0.4 : 1);
    lib.frequent.forEach((a, i) => add(a.artist, Math.max(1, 4 - i * 0.1)));
    lib.recent.forEach((a) => add(a.artist, 1.5));
    lib.starred.forEach((s) => add(s.artist, 0.8));
    if (Object.values(w).filter((v) => v > 0).length < 3) lib.sample.forEach((s) => add(s.artist, 0.05));
    return w;
  }

  function plan(lib, hist, now = Date.now()) {
    const w = weights(lib, hist, now), display = {}, genreOf = {};
    const note = (artist, genre) => {
      if (!artist) return;
      display[key(artist)] ??= artist;
      const g = (genre || "").trim();
      if (g) { genreOf[key(artist)] ??= {}; genreOf[key(artist)][g] = (genreOf[key(artist)][g] || 0) + 1; }
    };
    lib.frequent.forEach((a) => note(a.artist, a.genre)); lib.recent.forEach((a) => note(a.artist, a.genre));
    [...lib.sample, ...lib.starred, ...lib.fresh].forEach((s) => note(s.artist, s.genre));
    hist.forEach((r) => note(r.artist));
    const gW = {}, byG = {};
    for (const [a, v] of Object.entries(w)) {
      if (v <= 0 || !genreOf[a]) continue;
      const g = Object.entries(genreOf[a]).sort((x, y) => y[1] - x[1])[0][0];
      gW[g] = (gW[g] || 0) + v; (byG[g] ??= []).push([a, v]);
    }
    const sortKV = (x, y) => (y[1] - x[1]) || (x[0] < y[0] ? -1 : 1);
    const dailies = [], used = new Set();
    for (const [g] of Object.entries(gW).sort(sortKV).slice(0, 4)) {
      const seeds = byG[g].sort(sortKV).slice(0, 3).map(([a]) => display[a] || a);
      seeds.forEach((s) => used.add(key(s)));
      dailies.push({ genre: g, seeds });
    }
    const rest = Object.entries(w).filter(([a, v]) => v > 0 && !used.has(a)).sort(sortKV).map(([a]) => display[a] || a);
    for (let i = 0; dailies.length < 4 && i + 1 < rest.length; i += 3) dailies.push({ genre: null, seeds: rest.slice(i, i + 3) });
    return { dailies, poolKeys: dailies.flatMap((d) => (d.genre ? ["genre:" + d.genre] : d.seeds.map((s) => "artist:" + s))) };
  }

  function pick(pool, count, rand, score, perAlbum = 2) {
    // spread songs across artists and albums, but let a genre with only a few artists still fill the mix
    const artists = new Set(pool.map((s) => key(s.artist))).size, albums = new Set(pool.map((s) => s.albumId || s.album || s.id)).size;
    const maxArtist = Math.max(4, Math.ceil(count / Math.max(1, artists)) + 1);
    const maxAlbum = Math.max(perAlbum, Math.ceil(count / Math.max(1, albums)) + 1);
    return pickOnce(pool, count, rand, score, maxArtist, maxAlbum);
  }

  function pickOnce(pool, count, rand, score, maxArtist, perAlbum) {
    const seen = new Set();
    let items = [];
    for (const s of pool) if (!seen.has(s.id)) { seen.add(s.id); items.push([s, Math.max(0.01, score(s))]); }
    items.sort((a, b) => (a[0].id < b[0].id ? -1 : 1));
    const out = [], perArtist = {}, albums = {};
    while (out.length < count && items.length) {
      const total = items.reduce((t, it) => t + it[1], 0);
      let r = rand() * total, idx = items.length - 1;
      for (let i = 0; i < items.length; i++) { r -= items[i][1]; if (r <= 0) { idx = i; break; } }
      const s = items.splice(idx, 1)[0][0];
      const a = key(s.artist), al = s.albumId || s.album || s.id;
      if ((perArtist[a] || 0) >= maxArtist || (albums[al] || 0) >= perAlbum) continue;
      perArtist[a] = (perArtist[a] || 0) + 1; albums[al] = (albums[al] || 0) + 1;
      out.push(s);
    }
    const spread = [], restS = out.slice();
    while (restS.length) {
      const last = key(spread[spread.length - 1]?.artist);
      let i = restS.findIndex((s) => key(s.artist) !== last);
      if (i < 0) i = 0;
      spread.push(restS.splice(i, 1)[0]);
    }
    return spread;
  }

  function covers(songs) {
    const seen = new Set(), out = [];
    for (const s of songs) {
      const c = s.coverArt || s.albumId, k = s.albumId || c;
      if (!c || seen.has(k)) continue;
      seen.add(k); out.push(c);
      if (out.length === 4) break;
    }
    return out;
  }

  function build(lib, hist, nowMs = Date.now()) {
    const now = new Date(nowMs), day = dayKey(now), w = weights(lib, hist, nowMs);
    const recently = new Set(hist.filter((r) => nowMs - r.at < 3 * DAY).map((r) => r.id));
    const skipCount = {};
    hist.filter(skipped).forEach((r) => { skipCount[r.id] = (skipCount[r.id] || 0) + 1; });
    const starred = new Set(lib.starred.map((s) => s.id));
    const mixes = [];
    const mk = (m) => { m.covers = covers(m.songs); mixes.push(m); };

    plan(lib, hist, nowMs).dailies.forEach((d, n) => {
      let pool = d.genre ? (lib.pools["genre:" + d.genre] || []) : [];
      d.seeds.forEach((s) => { pool = pool.concat(lib.pools["artist:" + s] || []); });
      const seedKeys = new Set(d.seeds.map(key));
      pool = pool.concat(lib.sample.filter((s) => seedKeys.has(key(s.artist)) || (d.genre && s.genre === d.genre)));
      const songs = pick(pool, SIZE, rng(`${day}-daily-${n}`), (s) => {
        let sc = 1;
        const a = key(s.artist);
        if (seedKeys.has(a)) sc += 3;
        sc += Math.max(-0.5, Math.min(2, (w[a] || 0) * 0.3));
        if (starred.has(s.id)) sc += 1;
        if (s.playCount > 0) sc += Math.min(1, s.playCount * 0.1);
        if (recently.has(s.id)) sc *= 0.25;
        if ((skipCount[s.id] || 0) >= 2) sc *= 0.2;
        return sc;
      });
      if (songs.length < 8) return;
      const names = d.seeds.slice(0, 2).join(", ");
      const nth = mixes.filter((m) => m.kind === "daily").length + 1;
      mk({ id: "daily-" + nth, kind: "daily", title: "Daily Mix " + nth,
           subtitle: d.seeds.length > 2 ? `${names} and more` : names || d.genre || "Your favorites",
           hue: hue(d.genre || d.seeds.join("")), songs });
    });

    const p = part(now.getHours());
    const atThisTime = hist.filter((r) => part(new Date(r.at).getHours()) === p && !skipped(r));
    const pW = {};
    atThisTime.forEach((r) => { pW[key(r.artist)] = (pW[key(r.artist)] || 0) + 1; });
    const usePart = atThisTime.length >= 15;
    const ww = usePart ? pW : w;
    let timePool = usePart ? atThisTime.map(recSong) : [];
    timePool = timePool.concat(lib.sample.filter((s) => (ww[key(s.artist)] || 0) > 0), lib.starred);
    const timeSongs = pick(timePool, SIZE, rng(`${day}-${p}`), (s) => {
      let sc = 1 + Math.min(3, (ww[key(s.artist)] || 0) * 0.4);
      if (starred.has(s.id)) sc += 0.8;
      if (recently.has(s.id)) sc *= 0.5;
      return sc;
    });
    if (timeSongs.length >= 8) mk({ id: "time-" + p, kind: "timeOfDay", title: partTitle[p],
      subtitle: usePart ? "What you play around this time" : "Your favorites for right now", hue: hue(p), songs: timeSongs });

    const old = nowMs - 45 * DAY;
    const heardLately = new Set(hist.filter((r) => r.at > old).map((r) => r.id));
    const rePool = [...lib.sample, ...lib.starred].filter((s) => {
      if (heardLately.has(s.id)) return false;
      const pc = s.playCount || 0, played = s.played ? Date.parse(s.played) : NaN;
      if (!isNaN(played)) return pc >= 2 && played < old;
      return pc >= 4 || (starred.has(s.id) && pc >= 1);
    });
    const re = pick(rePool, 25, rng(`${day}-rediscover`), (s) => 1 + Math.min(3, (s.playCount || 0) * 0.2) + (starred.has(s.id) ? 1 : 0));
    if (re.length >= 8) mk({ id: "rediscover", kind: "rediscover", title: "Rediscover", subtitle: "Old favorites you haven't played lately", hue: 0.08, songs: re });

    const ever = new Set(hist.map((r) => r.id));
    const fresh = pick(lib.fresh.filter((s) => (s.playCount || 0) <= 1 && !ever.has(s.id)), 25, rng(`${day}-fresh`), () => 1, 3);
    if (fresh.length >= 6) mk({ id: "fresh", kind: "fresh", title: "Fresh Finds", subtitle: "New in your library", hue: 0.33, songs: fresh });

    const thatDay = hist.filter((r) => { const d = new Date(r.at); return d.getMonth() === now.getMonth() && d.getDate() === now.getDate() && d.getFullYear() < now.getFullYear() && !skipped(r); });
    if (thatDay.length >= 5) {
      const seen = new Set(), songs = thatDay.filter((r) => !seen.has(r.id) && seen.add(r.id)).map(recSong).slice(0, 40);
      const year = Math.max(...thatDay.map((r) => new Date(r.at).getFullYear()));
      mk({ id: "onthisday", kind: "onThisDay", title: "On This Day",
           subtitle: `What you played on ${now.toLocaleDateString(undefined, { month: "long", day: "numeric" })}, ${year}`, hue: 0.75, songs });
    }
    return mixes;
  }

  return { plan, build, pick, part, dayKey, key, SIZE };
})();
window.Mixer = Mixer;

/* ---------------- loading and keeping today's mixes ---------------- */
const mixStore = {
  saved: store.get("mixes", null),
  loading: null,
  key: () => { const d = new Date(); return `${Mixer.dayKey(d)}-${Mixer.part(d.getHours())}`; },
  get mixes() { return this.saved?.mixes || []; },
  find(id) { return this.mixes.find((m) => m.id === id); },
  refresh(force = false) {
    if (!force && this.saved && this.saved.key === this.key() && this.saved.user === cfg.user) return Promise.resolve(this.mixes);
    if (this.loading) return this.loading;
    this.loading = (async () => {
      const lib = { frequent: [], recent: [], sample: [], starred: [], fresh: [], pools: {} };
      const soft = (p, d) => p.catch(() => d);
      const [frequent, recent, newest, sample, starred] = await Promise.all([
        soft(lib_.albums("frequent", 40), []), soft(lib_.albums("recent", 30), []), soft(lib_.albums("newest", 12), []),
        api("getRandomSongs", { size: 500 }).then((r) => r.randomSongs?.song || []), soft(lib_.starred(), {})]);
      Object.assign(lib, { frequent, recent, sample, starred: starred.song || [] });
      lib.fresh = (await Promise.all(newest.map((a) => soft(lib_.album(a.id).then((x) => x.song || []), [])))).flat();
      const plan = Mixer.plan(lib, plays.list);
      await Promise.all(plan.poolKeys.map(async (k) => {
        if (k.startsWith("genre:")) {
          lib.pools[k] = await soft(api("getSongsByGenre", { genre: k.slice(6), count: 300 }).then((r) => r.songsByGenre?.song || []), []);
        } else {
          const name = k.slice(7);
          const found = await soft(api("search3", { query: name, artistCount: 0, albumCount: 0, songCount: 80 }).then((r) => r.searchResult3?.song || []), []);
          lib.pools[k] = found.filter((s) => Mixer.key(s.artist).includes(Mixer.key(name)));
        }
      }));
      const mixes = Mixer.build(lib, plays.list);
      this.saved = { key: this.key(), user: cfg.user, mixes };
      store.set("mixes", this.saved);
      return mixes;
    })().finally(() => { this.loading = null; });
    return this.loading;
  },
};
const lib_ = lib;

/* ---------------- weather (Open-Meteo, free, no key) ---------------- */
const weather = {
  get on() { return store.get("weatherOn", true); },
  get place() { return store.get("weatherPlace", "Fayetteville, AR"); },
  now: store.get("weatherNow", null),
  async refresh(force = false) {
    if (!this.on) return null;
    const w = this.now;
    if (!force && w && w.for === this.place && Date.now() - w.at < 20 * 60000) return w;
    try {
      let lat = 36.0626, lon = -94.1574, label = "Fayetteville";
      if (this.place !== "Fayetteville, AR") {
        const city = this.place.split(",")[0].trim();
        const g = await (await fetch(`https://geocoding-api.open-meteo.com/v1/search?name=${encodeURIComponent(city)}&count=1`)).json();
        const r = g.results?.[0];
        if (!r) return null;
        lat = r.latitude; lon = r.longitude; label = r.name;
      }
      const f = /^en-US|^en$/.test(navigator.language) || navigator.language === "en-US";
      const j = await (await fetch(`https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&current=temperature_2m,weather_code,is_day&temperature_unit=${f ? "fahrenheit" : "celsius"}`)).json();
      this.now = { temp: Math.round(j.current.temperature_2m), code: j.current.weather_code, day: j.current.is_day === 1, place: label, for: this.place, at: Date.now() };
      store.set("weatherNow", this.now);
      return this.now;
    } catch { return null; }
  },
  icon(c, day) {
    if (c === 0) return day ? "☀️" : "🌙";
    if (c <= 2) return day ? "⛅️" : "☁️";
    if (c === 3) return "☁️";
    if (c === 45 || c === 48) return "🌫️";
    if (c >= 51 && c <= 67 || c >= 80 && c <= 82) return "🌧️";
    if (c >= 71 && c <= 77 || c === 85 || c === 86) return "🌨️";
    if (c >= 95) return "⛈️";
    return "☁️";
  },
  words(c) {
    return c === 0 ? "Clear" : c === 1 ? "Mostly clear" : c === 2 ? "Partly cloudy" : c === 3 ? "Cloudy" : c === 45 || c === 48 ? "Foggy"
      : c >= 51 && c <= 57 ? "Drizzle" : c >= 61 && c <= 67 ? "Rain" : c >= 71 && c <= 77 || c === 85 || c === 86 ? "Snow"
      : c >= 80 && c <= 82 ? "Showers" : c >= 95 ? "Storms" : "";
  },
};

/* ---------------- accent color ---------------- */
const ACCENTS = { albumArt: ["Match Album Art", "#6ee8d9"], teal: ["Teal", "#6ee8d9"], red: ["Red", "#ff5c5c"], orange: ["Orange", "#ff9e4d"],
                  pink: ["Pink", "#ff73b8"], purple: ["Purple", "#b38fff"], blue: ["Blue", "#61adff"], lime: ["Lime", "#b8f25c"] };
const accent = {
  get choice() { return store.get("accent", "teal"); },
  set(choice) { store.set("accent", choice); this.apply(); },
  albumColor: null,
  apply() {
    const c = this.choice === "albumArt" ? (this.albumColor || ACCENTS.teal[1]) : (ACCENTS[this.choice] || ACCENTS.teal)[1];
    document.documentElement.style.setProperty("--accent", c);
  },
};

/* ---------------- Home ---------------- */
const greeting = (h) => (h >= 5 && h < 12 ? "Good morning" : h >= 12 && h < 17 ? "Good afternoon" : h >= 17 && h < 22 ? "Good evening" : "Up late");

function mixArt(m, size) {
  const c = m.covers || [];
  const tint = `hsl(${Math.round(m.hue * 360)} 75% 55%)`;
  const grid = c.length >= 4 ? `<div class="mix-grid">${c.slice(0, 4).map((id) => `<img loading="lazy" src="${cover(id, size > 200 ? 400 : 160)}" alt="">`).join("")}</div>`
    : c.length ? `<img class="mix-one" loading="lazy" src="${cover(c[0], 400)}" alt="">` : "";
  const ic = { daily: "✦", rediscover: "↺", fresh: "❋", timeOfDay: "◷", onThisDay: "▦" }[m.kind] || "✦";
  return `<div class="mix-art" style="--mix:${tint};width:${size}px;height:${size}px">${grid}<div class="mix-wash"></div>
    <div class="mix-label"><i>${ic}</i><b style="font-size:${Math.round(size * 0.11)}px">${esc(m.title)}</b></div></div>`;
}

function headerHTML() {
  const d = new Date();
  const w = weather.on ? weather.now : null;
  const day = d.toLocaleDateString(undefined, { weekday: "long" }), time = d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  return `<div class="home-head">
    <div class="hh-line"><span class="hh-date" title="${esc(d.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" }))}">${esc(day)}</span>
      <span class="hh-dot">·</span><span class="hh-time">${esc(time)}</span>
      ${w ? `<span class="hh-dot">·</span><span class="hh-weather" title="${esc(weather.words(w.code))} in ${esc(w.place)}">${weather.icon(w.code, w.day)} ${w.temp}°</span>` : ""}</div>
    <div class="hh-row"><h1 class="title hh-greet">${greeting(d.getHours())}</h1>
      <button class="hh-shuffle" id="shuffle-all" aria-label="Shuffle all your music">${icon("shuffle")}</button></div></div>`;
}

/** The quick picks: what you've been playing, as a tidy grid of small tiles (Spotify-style). */
function quickPick(a, i) {
  return `<a class="qp appear" style="--d:${i * 30}ms" href="#/album/${esc(a.id)}"><img loading="lazy" src="${cover(a.coverArt, 120)}" alt="">
    <span><b>${esc(a.name)}</b><small>${esc(a.artist || "")}</small></span></a>`;
}

function continueHTML() {
  const t = player.current;
  if (!t || player.playing) return "";
  const d = t.duration || 0, at = player.el ? player.time() : (player.resumeAt || 0);
  return `<button class="continue" id="continue"><img src="${cover(t.coverArt, 160)}" alt="">
    <span class="c-meta"><small>Continue Listening</small><b>${esc(t.title)}</b><span>${esc(t.artist)}</span>
    <i class="c-prog"><i style="width:${d ? Math.min(100, (at / d) * 100) : 0}%"></i></i></span>
    <span class="c-play">${icon("play")}</span></button>`;
}

screens.home = async function home() {
  const token = routeToken;
  view.innerHTML = `${headerHTML()}<div id="continue-slot">${continueHTML()}</div>
    <div class="qp-grid" id="quick"></div>
    <div class="section" id="mfy"><div class="section-head"><h2 class="h2">Made for You</h2></div>
      <div class="shelf" id="mixes">${mixStore.mixes.length ? "" : '<div class="mix-ph"></div><div class="mix-ph"></div><div class="mix-ph"></div>'}</div></div>
    <div id="shelves"></div>`;
  const shuffle = () => { $("#shuffle-all").onclick = async () => { try { player.play(await lib.random(100)); } catch (e) { toast(e.message); } }; };
  shuffle();
  const cont = $("#continue");
  if (cont) cont.onclick = () => { player.resume(); };
  const renderMixes = (list) => {
    const box = $("#mixes");
    if (!box || token !== routeToken) return;
    if (!list.length) { $("#mfy").hidden = true; return; }
    box.innerHTML = list.map((m, i) => `<a class="card mix-card appear" style="--d:${i * 40}ms" href="#/mix/${esc(m.id)}" title="${esc(m.subtitle)}">${mixArt(m, 136)}</a>`).join("");
  };
  if (mixStore.mixes.length) renderMixes(mixStore.mixes);
  mixStore.refresh().then(renderMixes).catch(() => { if (!mixStore.mixes.length && $("#mfy")) $("#mfy").hidden = true; });
  weather.refresh().then((w) => {
    if (!w || token !== routeToken) return;
    const head = $(".home-head");
    if (head) { head.outerHTML = headerHTML(); shuffle(); }
  });
  try {
    const [recent, frequent, added] = await Promise.all(["recent", "frequent", "newest"].map((t) => lib.albums(t, 20)));
    if (token !== routeToken) return;
    // one grid of what you've been playing (recent first, then favorites), and new music you haven't seen up there
    const seen = new Set(), picks = [];
    for (const a of [...recent, ...frequent]) { if (picks.length >= 6) break; if (!seen.has(a.id)) { seen.add(a.id); picks.push(a); } }
    const fresh = added.filter((a) => !seen.has(a.id)).slice(0, 12);
    $("#quick").innerHTML = picks.map(quickPick).join("");
    $("#quick").hidden = !picks.length;
    $("#shelves").innerHTML = (fresh.length ? `<div class="section"><div class="section-head"><h2 class="h2">New in Your Library</h2>
      <a class="more" href="#/library">See all</a></div>
      <div class="shelf">${fresh.map((a, i) => albumCard(a).replace('class="card"', `class="card small appear" style="--d:${i * 30}ms"`)).join("")}</div></div>` : "")
      || (picks.length ? "" : `<div class="empty"><b>Your library is empty</b>Navidrome hasn't found any music yet.</div>`);
  } catch (e) { if ($("#shelves")) $("#shelves").innerHTML = errorBox(e); }
};

screens.mix = async function mixScreen(id) {
  let m = mixStore.find(id);
  if (!m) { view.innerHTML = loading(); try { await mixStore.refresh(); } catch { /* shown below */ } m = mixStore.find(id); }
  if (!m) { view.innerHTML = backLink() + `<div class="empty"><b>This mix has changed</b>Mixes refresh every day. Pick one from Home.</div>`; return; }
  screenTracks = m.songs.map(toTrack);
  const total = screenTracks.reduce((s, t) => s + t.duration, 0);
  view.innerHTML = `<div class="album-wash mix-page" style="--a-top:hsl(${Math.round(m.hue * 360)} 45% 28%)">${backLink()}
    <div class="album-head">${mixArt(m, 230)}<h1>${esc(m.title)}</h1><span class="by" style="color:var(--sec)">${esc(m.subtitle)}</span>
      <small>${screenTracks.length} songs · ${Math.round(total / 60)} min</small></div>
    ${playButtons()}
    <div class="pill-row" style="margin-top:10px"><button class="pill" id="mix-save">${icon("playlist")}Save as Playlist</button></div>
    <div style="margin-top:14px">${screenTracks.map((t, i) => trackRow(t, i)).join("")}</div></div>`;
  $("#mix-save").onclick = async () => {
    const b = $("#mix-save");
    b.disabled = true;
    const name = `${m.title} · ${new Date().toLocaleDateString(undefined, { month: "short", day: "numeric" })}`;
    const qs = m.songs.map((s) => `songId=${encodeURIComponent(s.id)}`).join("&");
    try {
      const r = await fetch(`rest/createPlaylist?${auth()}&name=${encodeURIComponent(name)}&${qs}`);
      const j = await r.json();
      if (j["subsonic-response"]?.status !== "ok") throw new Error("not saved");
      b.innerHTML = `${icon("check")}Saved to Playlists`;
    } catch { b.disabled = false; toast("Couldn't save the playlist."); }
  };
};

/* ---------------- artist page: photo, bio, similar artists ---------------- */
const plainBio = (html) => String(html || "").replace(/<a[^>]*>.*?<\/a>/g, "").replace(/<[^>]+>/g, "")
  .replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;/g, "'").trim();
const realImage = (u) => u && !u.includes("2a96cbd8b46e442fc41c2b86b821562f");

screens.artist = async function artist(id) {
  view.innerHTML = loading();
  try {
    const a = await lib.artist(id);
    const albums = (a.album || []).sort((x, y) => (y.year || 0) - (x.year || 0));
    const heroImg = realImage(a.artistImageUrl) ? a.artistImageUrl : null;
    view.innerHTML = `<div class="artist-hero" id="ahero">${heroImg ? `<img src="${esc(heroImg)}" alt="">` : albums[0] ? `<img class="soft" src="${cover(albums[0].coverArt || albums[0].id, 400)}" alt="">` : ""}
        <div class="ah-fade"></div>${backLink()}<h1>${esc(a.name)}</h1></div>
      <div class="pill-row"><button class="pill primary" id="art-play">${icon("play")}Play</button><button class="pill" id="art-shuffle">${icon("shuffle")}Shuffle</button></div>
      <div id="bio"></div>
      <div class="section"><div class="section-head"><h2 class="h2">Albums</h2></div>
      <div class="grid">${albums.map((al, i) => albumCard({ ...al, artist: al.year || "" }).replace('class="card"', `class="card appear" style="--d:${i * 25}ms"`)).join("")}</div></div>
      <div id="similar"></div>`;
    const all = async (shuffle) => {
      const lists = await Promise.all(albums.map((al) => lib.album(al.id).then((x) => (x.song || []).map(toTrack)).catch(() => [])));
      player.play(lists.flat(), 0, shuffle);
    };
    $("#art-play").onclick = () => all(false);
    $("#art-shuffle").onclick = () => all(true);
    const token = routeToken;
    const info = await api("getArtistInfo2", { id, count: 12, includeNotPresent: false }).then((r) => r.artistInfo2 || {}).catch(() => ({}));
    if (token !== routeToken) return;
    if (realImage(info.largeImageUrl) && !heroImg) {
      const img = new Image();
      img.onload = () => { const h = $("#ahero img"); if (h) { h.src = info.largeImageUrl; h.classList.remove("soft"); } };
      img.src = info.largeImageUrl;
    }
    const bio = plainBio(info.biography);
    if (bio) {
      $("#bio").innerHTML = `<div class="section bio"><div class="section-head"><h2 class="h2">About</h2></div><p class="clamp">${esc(bio)}</p><button class="more-link">More</button></div>`;
      const btn = $("#bio .more-link");
      btn.onclick = () => { const p = $("#bio p"); p.classList.toggle("clamp"); btn.textContent = p.classList.contains("clamp") ? "More" : "Less"; };
    }
    const sim = info.similarArtist || [];
    if (sim.length) {
      $("#similar").innerHTML = `<div class="section"><div class="section-head"><h2 class="h2">Fans Also Like</h2></div><div class="shelf">${sim.map((s) =>
        `<a class="card sim" href="#/artist/${esc(s.id)}"><img class="art round" loading="lazy" src="${realImage(s.artistImageUrl) ? esc(s.artistImageUrl) : cover(s.coverArt || s.id, 160)}" alt=""><b>${esc(s.name)}</b></a>`).join("")}</div></div>`;
    }
  } catch (e) { view.innerHTML = backLink() + errorBox(e); }
};

/* ---------------- settings additions ---------------- */
const baseSettings = screens.settings;
screens.settings = async function settings() {
  await baseSettings();
  const box = document.createElement("div");
  box.innerHTML = `<div class="form" style="margin-top:26px">
      <label><span>Accent color</span><select id="s-accent">${Object.entries(ACCENTS).map(([k, [n]]) => `<option value="${k}">${n}</option>`).join("")}</select></label>
      <label style="display:flex;align-items:center;justify-content:space-between"><span style="font-size:17px;color:#fff">Weather on Home</span><input type="checkbox" id="s-weather" style="width:auto"></label>
      <label id="s-place-row"><span>Weather city</span><input id="s-place" autocomplete="off"></label>
    </div><p class="note">Match Album Art makes buttons and highlights take on the color of the song that's playing.</p>`;
  const anchor = $("#s-eq")?.closest(".form");
  if (anchor) anchor.after(box); else view.appendChild(box);
  $("#s-accent").value = accent.choice;
  $("#s-accent").onchange = (e) => accent.set(e.target.value);
  $("#s-weather").checked = weather.on;
  $("#s-place").value = weather.place;
  $("#s-place-row").hidden = !weather.on;
  $("#s-weather").onchange = (e) => { store.set("weatherOn", e.target.checked); $("#s-place-row").hidden = !e.target.checked; };
  $("#s-place").onchange = (e) => { store.set("weatherPlace", e.target.value.trim() || "Fayetteville, AR"); weather.refresh(true); };
};

/* ---------------- wiring ---------------- */
window.onTrackStart = (t) => { plays.started(t); session.save(); };
window.onAlbumColor = (c) => { accent.albumColor = c; if (accent.choice === "albumArt") accent.apply(); };
setInterval(() => { if (player.playing) session.save(); }, 5000);
window.addEventListener("pagehide", () => session.save());
accent.apply();
session.restore();
Object.assign(window, { plays, session, mixStore, weather, accent });
