/* Platter web: Wrapped. Your listening for this month, this year or all time, from the play history that the app and
   the web player share (through the helper on the NAS). Same rules as the app (ios/Needle/Core/Wrapped.swift). */
"use strict";

const Wrapped = (() => {
  const DAY = 86400000;
  const SLOWED = ["slowed", "screwed", "syrup"];
  const PERSONAS = [
    // hours (start..end), name, line
    [5, 12, "Early Bird", "of your listening happens in the morning"],
    [12, 17, "Afternoon Cruiser", "of your listening happens in the afternoon"],
    [17, 22, "Evening Rider", "of your listening happens in the evening"],
    [22, 29, "Night Owl", "of your listening happens after 10 PM"],
  ];

  function periodRange(period, now = new Date()) {
    const d = new Date(now);
    if (period === "month") return { from: new Date(d.getFullYear(), d.getMonth(), 1).getTime(), to: now.getTime(),
      label: d.toLocaleDateString(undefined, { month: "long" }) };
    if (period === "year") return { from: new Date(d.getFullYear(), 0, 1).getTime(), to: now.getTime(), label: String(d.getFullYear()) };
    return { from: 0, to: now.getTime(), label: "All Time" };
  }

  /** How long each play really lasted: what was recorded, or until the next play started, at most the song. */
  function listenedSeconds(recs) {
    return recs.map((r, i) => {
      if (typeof r.listened === "number") return Math.max(0, Math.min(r.listened, r.duration || r.listened));
      const next = recs[i + 1];
      const gap = next ? (next.at - r.at) / 1000 : Infinity;
      return Math.max(0, Math.min(r.duration || 0, gap));
    });
  }

  const dayKey = (t) => { const d = new Date(t); return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`; };

  /** Everything the Wrapped page shows. `all` is the whole history (oldest first); only plays in the period count. */
  function compute(all, period, now = new Date()) {
    const recs = [...all].filter((r) => r && r.id && typeof r.at === "number").sort((a, b) => a.at - b.at);
    const secs = listenedSeconds(recs);
    const range = periodRange(period, now);
    const firstPlayOfArtist = new Map();
    recs.forEach((r) => { const a = (r.artist || "").trim(); if (a && !firstPlayOfArtist.has(a.toLowerCase())) firstPlayOfArtist.set(a.toLowerCase(), r.at); });

    const songs = new Map(), artists = new Map(), albums = new Map(), hours = new Array(24).fill(0), days = new Map();
    let minutes = 0, plays = 0, slowedMin = 0;
    const speeds = {};
    recs.forEach((r, i) => {
      if (r.at < range.from || r.at > range.to) return;
      const s = secs[i], m = s / 60;
      if (s < Math.min(30, (r.duration || 60) * 0.5)) return;          // skips don't count
      plays++; minutes += m;
      const song = songs.get(r.id) || { id: r.id, title: r.title, artist: r.artist, album: r.album, albumId: r.albumId, coverArt: r.coverArt, plays: 0, minutes: 0 };
      song.plays++; song.minutes += m; songs.set(r.id, song);
      const ak = (r.artist || "Unknown").trim(), a = artists.get(ak.toLowerCase()) || { name: ak, plays: 0, minutes: 0, covers: new Map() };
      a.plays++; a.minutes += m; a.covers.set(r.coverArt, (a.covers.get(r.coverArt) || 0) + 1); artists.set(ak.toLowerCase(), a);
      if (r.album) {
        const bk = `${r.album}|${r.artist}`, b = albums.get(bk) || { name: r.album, artist: r.artist, albumId: r.albumId, coverArt: r.coverArt, minutes: 0, plays: 0 };
        b.minutes += m; b.plays++; albums.set(bk, b);
      }
      hours[new Date(r.at).getHours()] += m;
      const dk = dayKey(r.at); days.set(dk, { at: r.at, minutes: (days.get(dk)?.minutes || 0) + m });
      if (r.speed) speeds[r.speed] = (speeds[r.speed] || 0) + m;
      if (SLOWED.includes(r.speed)) slowedMin += m;
    });

    const ranked = [...songs.values()].sort((a, b) => b.plays - a.plays || b.minutes - a.minutes);
    const topSongs = ranked.slice(0, 5);
    const topArtists = [...artists.values()].sort((a, b) => b.minutes - a.minutes || b.plays - a.plays).slice(0, 5)
      .map((a) => ({ name: a.name, plays: a.plays, minutes: a.minutes, coverArt: [...a.covers.entries()].sort((x, y) => y[1] - x[1])[0]?.[0] }));
    const topAlbum = [...albums.values()].sort((a, b) => b.minutes - a.minutes)[0] || null;

    // listening personality: the part of the day with the most minutes
    let persona = null;
    if (minutes > 0) {
      const part = PERSONAS.map(([from, to, name, line]) => {
        let m = 0; for (let h = from; h < to; h++) m += hours[h % 24];
        return { name, line, share: m / minutes };
      }).sort((a, b) => b.share - a.share)[0];
      persona = part;
    }
    // streaks: days in a row with any listening
    const dayList = [...days.values()].map((d) => { const x = new Date(d.at); return new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime(); }).sort((a, b) => a - b);
    let longest = 0, run = 0, prev = null;
    for (const d of dayList) { run = prev !== null && Math.round((d - prev) / DAY) === 1 ? run + 1 : 1; longest = Math.max(longest, run); prev = d; }
    const biggest = [...days.values()].sort((a, b) => b.minutes - a.minutes)[0] || null;
    const newArtists = [...artists.values()].filter((a) => (firstPlayOfArtist.get(a.name.toLowerCase()) || 0) >= range.from)
      .sort((a, b) => b.minutes - a.minutes);
    const topSpeed = Object.entries(speeds).filter(([k]) => SLOWED.includes(k)).sort((a, b) => b[1] - a[1])[0];

    return {
      period, label: range.label, plays, minutes: Math.round(minutes),
      songs: songs.size, artists: artists.size,
      topSongs, topArtists, topAlbum, persona, playlist: ranked.slice(0, 50),
      hours: hours.map((m) => Math.round(m)),
      longestStreak: longest, activeDays: days.size,
      biggestDay: biggest ? { at: biggest.at, minutes: Math.round(biggest.minutes) } : null,
      newArtists: { count: newArtists.length, names: newArtists.slice(0, 3).map((a) => a.name) },
      slowed: { share: minutes ? slowedMin / minutes : 0, favorite: topSpeed ? topSpeed[0] : null },
    };
  }

  return { compute, periodRange, listenedSeconds };
})();
if (typeof module !== "undefined") module.exports = { Wrapped };
