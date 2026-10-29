/* Wrapped math (run: node test_wrapped.js). */
const { Wrapped } = require(require("path").join(__dirname, "..", "site", "wrapped.js"));
let pass = 0, fail = 0;
const check = (name, ok, info = "") => { ok ? pass++ : fail++; console.log(`${ok ? "PASS" : "FAIL"} ${name}${info !== "" ? "   [" + JSON.stringify(info) + "]" : ""}`); };
const now = new Date(2026, 9, 29, 12, 0);           // Oct 29 2026, noon
const at = (m, d, h, min = 0) => new Date(2026, m, d, h, min).getTime();
const song = (id, artist, album, dur = 200) => ({ id, title: "Song " + id, artist, album, albumId: "al-" + album, coverArt: "c-" + id, duration: dur });
const recs = [];
// last year: an artist you already knew
recs.push({ ...song("old", "UGK", "Ridin' Dirty"), at: new Date(2025, 5, 1, 20).getTime(), listened: 200 });
// October: nights with Three 6 Mafia, slowed; a daytime Drake run; a skip
for (let d = 10; d <= 16; d++) recs.push({ ...song("t6a", "Three 6 Mafia", "Mystic Stylez"), at: at(9, d, 23), listened: 200, speed: "screwed", device: "phone" });
for (let d = 10; d <= 12; d++) recs.push({ ...song("t6b", "Three 6 Mafia", "Mystic Stylez"), at: at(9, d, 23, 10), listened: 180, speed: "screwed", device: "web" });
recs.push({ ...song("dr1", "Drake", "Views"), at: at(9, 20, 14), listened: 220 });
recs.push({ ...song("dr1", "Drake", "Views"), at: at(9, 21, 14) });                 // no listened: until the next play
recs.push({ ...song("ugk2", "UGK", "Ridin' Dirty"), at: at(9, 21, 14, 2) , listened: 5 });   // skipped
recs.push({ ...song("ugk3", "UGK", "Ridin' Dirty"), at: at(9, 22, 1), listened: 200 });
// September (this year, not this month)
recs.push({ ...song("sep", "Koopsta Knicca", "Da Devil's Playground"), at: at(8, 5, 22), listened: 200 });

const m = Wrapped.compute(recs, "month", now);
check("month label", m.label === "October", m.label);
check("skips don't count", m.plays === 7 + 3 + 2 + 1, m.plays);
check("minutes add up (a play with no end time lasts until the next one)", m.minutes === Math.round((7 * 200 + 3 * 180 + 220 + 120 + 200) / 60), m.minutes);
check("top song", m.topSongs[0].id === "t6a" && m.topSongs[0].plays === 7, m.topSongs[0]);
check("top artist by minutes", m.topArtists[0].name === "Three 6 Mafia" && m.topArtists[0].coverArt === "c-t6a", m.topArtists[0]);
check("top album", m.topAlbum.name === "Mystic Stylez", m.topAlbum);
check("night owl", m.persona.name === "Night Owl" && m.persona.share > 0.6, m.persona);
check("longest streak of days in a row", m.longestStreak === 7, m.longestStreak);
check("biggest day", new Date(m.biggestDay.at).getDate() <= 12 && m.biggestDay.minutes === Math.round((200 + 180) / 60), m.biggestDay);
check("new artists this month (UGK you already knew)", m.newArtists.count === 2 && m.newArtists.names.includes("Drake") && !m.newArtists.names.includes("UGK"), m.newArtists);
check("how much was slowed down", Math.abs(m.slowed.share - (7 * 200 + 3 * 180) / (7 * 200 + 3 * 180 + 220 + 120 + 200)) < 0.01 && m.slowed.favorite === "screwed", m.slowed);
const y = Wrapped.compute(recs, "year", now);
check("year includes September", y.plays === m.plays + 1 && y.label === "2026", [y.plays, y.label]);
const a = Wrapped.compute(recs, "all", now);
check("all time includes last year", a.plays === y.plays + 1);
check("empty history is fine", Wrapped.compute([], "month", now).plays === 0);
console.log(`\n${pass} passed, ${fail} failed`);
if (fail) process.exitCode = 1;
