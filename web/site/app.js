/* Needle web player — streams your Navidrome library through a real 10-band EQ. */
"use strict";

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const icon = (name) => `<svg class="i"><use href="#i-${name}"/></svg>`;
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const fmt = (s) => {
  if (!isFinite(s) || s < 0) s = 0;
  s = Math.floor(s);
  return s >= 3600 ? `${Math.floor(s / 3600)}:${String(Math.floor(s / 60) % 60).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`
                   : `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};
const store = {
  get(k, d) { try { const v = localStorage.getItem("needle." + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem("needle." + k, JSON.stringify(v)); } catch { /* private mode */ } },
};

function toast(msg) {
  const t = $("#toast");
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (t.hidden = true), 3800);
}

/* ============================================================
   Server (Subsonic API via the NAS proxy at /rest)
   ============================================================ */
let cfg = store.get("cfg", { user: "", pass: "" });
let quality = store.get("quality", "original");
const sessionSalt = Math.random().toString(36).slice(2, 10);

function auth(fixed) {
  const salt = fixed ? sessionSalt : Math.random().toString(36).slice(2, 10);
  return `u=${encodeURIComponent(cfg.user)}&t=${md5(cfg.pass + salt)}&s=${salt}&v=1.16.1&c=PlatterWeb&f=json`;
}
function rest(ep, params = {}, fixed = false) {
  const q = Object.entries(params).filter(([, v]) => v != null)
    .flatMap(([k, v]) => (Array.isArray(v) ? v : [v]).map((x) => `${k}=${encodeURIComponent(x)}`)).join("&");
  return `rest/${ep}?${auth(fixed)}${q ? "&" + q : ""}`;
}
async function api(ep, params) {
  let r;
  try { r = await fetch(rest(ep, params)); } catch { throw new Error("Can't reach your server."); }
  if (r.url.includes("cloudflareaccess.com")) throw new Error("Cloudflare is asking you to sign in. Reload the page.");
  if (!r.ok) throw new Error(`The server answered with error ${r.status}.`);
  let j;
  try { j = await r.json(); } catch { throw new Error("The server sent something unexpected."); }
  const res = j["subsonic-response"];
  if (!res || res.status !== "ok") throw new Error(res?.error?.message || "The server reported an error.");
  return res;
}
const cover = (id, size = 300) => id ? rest("getCoverArt", { id, size: size <= 160 ? 160 : size <= 400 ? 400 : 900 }, true) : "icons/icon-512.png";

function toTrack(s) {
  return { id: s.id, title: s.title, artist: s.artist || "Unknown Artist", album: s.album || "Unknown Album",
           albumId: s.albumId, artistId: s.artistId, duration: s.duration || 0, coverArt: s.coverArt || s.albumId,
           track: s.track, disc: s.discNumber, suffix: (s.suffix || "").toLowerCase(), starred: !!s.starred };
}
function streamURL(t) {
  if (t.local) return t.local;
  const playable = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "alac"];
  if (quality === "original" && playable.includes(t.suffix)) return rest("stream", { id: t.id, format: "raw" });
  return rest("stream", { id: t.id, format: "mp3", maxBitRate: quality === "saver" ? 160 : 320 });
}

const lib = {
  albums: (type, size = 20, offset = 0) => api("getAlbumList2", { type, size, offset }).then((r) => r.albumList2?.album || []),
  album: (id) => api("getAlbum", { id }).then((r) => r.album),
  artists: () => api("getArtists").then((r) => (r.artists?.index || []).flatMap((i) => i.artist || [])),
  artist: (id) => api("getArtist", { id }).then((r) => r.artist),
  playlists: () => api("getPlaylists").then((r) => r.playlists?.playlist || []),
  playlist: (id) => api("getPlaylist", { id }).then((r) => r.playlist),
  search: (query) => api("search3", { query, artistCount: 8, albumCount: 20, songCount: 40 }).then((r) => r.searchResult3 || {}),
  /** The library artist with exactly this name (or the closest match). */
  searchArtist: (name) => api("search3", { query: name, artistCount: 5, albumCount: 0, songCount: 0 }).then((r) => {
    const list = (r.searchResult3 && r.searchResult3.artist) || [];
    return list.find((a) => a.name.toLowerCase() === name.toLowerCase()) || list[0] || null;
  }),
  random: (size) => api("getRandomSongs", { size }).then((r) => (r.randomSongs?.song || []).map(toTrack)),
  starred: () => api("getStarred2").then((r) => r.starred2 || {}),
  star: (id, on) => api(on ? "star" : "unstar", { id }),
  createPlaylist: (name, songIds) => api("createPlaylist", { name, songId: songIds }).then((r) => r.playlist),
  addToPlaylist: (id, songIds) => api("updatePlaylist", { playlistId: id, songIdToAdd: songIds }),
  removeFromPlaylist: (id, indexes) => api("updatePlaylist", { playlistId: id, songIndexToRemove: indexes }),
  scrobble: (id) => api("scrobble", { id, submission: true }).catch(() => {}),
};

/* ============================================================
   Equalizer (Web Audio)
   ============================================================ */
const FREQS = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
const LABELS = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"];
const PRESETS = [
  ["Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]],
  ["Bass Boost", [6, 5.5, 4.5, 2.5, 0.5, 0, 0, 0, 0, 0]],
  ["Deep Bass", [8, 7, 5, 2, 0, -1, -1, 0, 0, 0]],
  ["Treble Boost", [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 6]],
  ["Vocal", [-2, -2, -1, 1, 3, 4, 3.5, 1.5, 0, -1]],
  ["Hip-Hop", [6, 5, 2, 3, -1, -1, 1, 0, 2, 3]],
  ["Rock", [5, 4, 2, -1, -2, -1, 2, 3, 4, 4]],
  ["Pop", [-1, 1, 3, 4, 3, 0, -1, -1, 0, 1]],
  ["Electronic", [5, 4, 1, 0, -2, 2, 1, 2, 4, 5]],
  ["Acoustic", [3, 3, 2, 1, 1, 1, 2, 2.5, 2, 1]],
  ["Loudness", [5, 3.5, 0, 0, -1, 0, -1, 0, 3.5, 5]],
  ["Late Night", [3, 2.5, 1, 0, -1, -1.5, 0, 1, 1, 0.5]],
  ["Small Speakers", [-4, -2, 3, 4, 3, 1, 1, 2, 2, 1]],
].map(([name, gains]) => ({ name, gains, builtIn: true }));

const eq = Object.assign({ gains: Array(10).fill(0), preamp: 0, enabled: true, guard: true, preset: "Flat", custom: [] }, store.get("eq", {}));
const saveEQ = () => store.set("eq", eq);
const allPresets = () => PRESETS.concat(eq.custom);

/* ============================================================
   Slowed / chopped & screwed (same as the app: ios/Needle/Audio/Screw.swift)
   ============================================================ */
const SPEEDS = { off: ["Off", 1, "Normal speed"], slowed: ["Slowed", 0.88, "A little slower and deeper"], screwed: ["Screwed", 0.8, "DJ Screw speed"],
                 syrup: ["Syrup", 0.72, "Extra slow and heavy"], spedUp: ["Sped Up", 1.18, "Faster and higher"] };
const screw = {
  speed: store.get("screwSpeed", "off"),
  chops: store.get("screwChops", "off"),
  stats: null,
  get rate() { return (SPEEDS[this.speed] || SPEEDS.off)[1]; },
  get routed() { return eq.enabled || this.chops !== "off" || !!(window.vizUI && vizUI.on); },
  label() {
    const s = SPEEDS[this.speed][0];
    if (this.speed === "off") return this.chops === "off" ? "" : this.chops === "live" ? "Live Chops" : "Chopped";
    if (this.chops === "off") return s;
    if (this.chops === "live") return `${s} + Live Chops`;
    return this.speed === "screwed" || this.speed === "syrup" ? `${s} & Chopped` : `${s} + Chops`;
  },
  applyTo(el) {
    if (!el) return;
    el.preservesPitch = false; el.webkitPreservesPitch = false; el.mozPreservesPitch = false;   // slower = deeper, like a record
    el.defaultPlaybackRate = this.rate;
    el.playbackRate = this.rate;
  },
  set(speed, chops) {
    if (speed) { this.speed = speed; store.set("screwSpeed", speed); }
    if (chops) { this.chops = chops; store.set("screwChops", chops); }
    this.applyTo(player.el); this.applyTo(player.next);
    audio.setChops(this.chops);
    player.reroute();
    ui.update();
  },
};

/* Live chops: tap a pad (or keys 1-5) and it cuts back right away, in time. Hold Repeat to loop the beat. */
const livePads = {
  el: null,
  keys: { 1: "loop", 2: "stutter", 3: "doubleUp", 4: "runBack", 5: "backItUp" },
  init() {
    this.el = $("#np-pads");
    this.el.addEventListener("pointerdown", (e) => {
      const b = e.target.closest("[data-move]");
      if (!b) return;
      e.preventDefault();
      try { b.setPointerCapture(e.pointerId); } catch {}
      this.press(b.dataset.move);
    });
    const up = (e) => { if (e.target.closest && e.target.closest("[data-move='loop']")) this.lift("loop"); };
    this.el.addEventListener("pointerup", up);
    this.el.addEventListener("pointercancel", up);
    this.el.addEventListener("contextmenu", (e) => e.preventDefault());     // long-press on phones holds the loop, no menu
    document.addEventListener("keydown", (e) => {
      const m = this.keys[e.key];
      if (!m || e.repeat || this.el.hidden || $("#np").hidden || /INPUT|TEXTAREA/.test(document.activeElement?.tagName)) return;
      this.press(m);
    });
    document.addEventListener("keyup", (e) => { if (this.keys[e.key] === "loop") this.lift("loop"); });
  },
  show(on) {
    if (!this.el) this.init();
    this.el.hidden = !on;
    this.status();
  },
  press(move) {
    audio.ensure();
    audio.trigger(move, move === "loop");
    const b = $(`[data-move='${move}']`, this.el);
    b.classList.add("down");
    if (navigator.vibrate) navigator.vibrate(8);
  },
  lift(move) {
    audio.release();
    $(`[data-move='${move}']`, this.el).classList.remove("down");
  },
  log: [],
  fired(move, ok) {
    this.log.push([move, ok]);
    const b = this.el && $(`[data-move='${move}']`, this.el);
    if (!b) return;
    if (move !== "loop") setTimeout(() => b.classList.remove("down"), 120);
    b.classList.remove("hit", "miss");
    void b.offsetWidth;
    b.classList.add(ok ? "hit" : "miss");
  },
  status() {
    if (!this.el || this.el.hidden) return;
    const st = screw.stats, locked = !!(st && st.confidence > 0.15 && st.bpm > 0);
    this.el.classList.toggle("waiting", !locked);
    this.el.title = locked ? `Locked on beat · ${Math.round(st.bpm)} BPM` : "Finding the beat…";
  },
};

const audio = {
  ctx: null, filters: [], pre: null, analyser: null, vizAnalyser: null, freqData: null,
  ensure() {
    if (this.ctx) { if (this.ctx.state === "suspended") this.ctx.resume(); return; }
    const C = window.AudioContext || window.webkitAudioContext;
    if (!C) return;
    this.ctx = new C();
    this.filters = FREQS.map((f, i) => {
      const b = this.ctx.createBiquadFilter();
      b.type = i === 0 ? "lowshelf" : i === 9 ? "highshelf" : "peaking";
      b.frequency.value = f;
      b.Q.value = 1.41;
      return b;
    });
    for (let i = 0; i < 9; i++) this.filters[i].connect(this.filters[i + 1]);
    this.pre = this.ctx.createGain();
    this.analyser = this.ctx.createAnalyser();
    this.analyser.fftSize = 4096;
    this.analyser.smoothingTimeConstant = 0.72;
    this.freqData = new Float32Array(this.analyser.frequencyBinCount);
    this.vizAnalyser = this.ctx.createAnalyser();     // snappier one for the visualizer's beat detection
    this.vizAnalyser.fftSize = 2048;
    this.vizAnalyser.smoothingTimeConstant = 0.35;
    this.filters[9].connect(this.pre);
    this.pre.connect(this.vizAnalyser);
    this.vizAnalyser.connect(this.analyser);
    this.analyser.connect(this.ctx.destination);
    this.apply();
    // chops run on the audio thread, between the EQ and the meters
    const onChopMessage = (d) => {
      if ("fired" in d) return livePads.fired(d.fired, d.ok);
      if ("scratched" in d) return turntable.scratched(d.scratched);
      if ("tape" in d) return turntable.tape(d.tape);
      screw.stats = d; this.lag = d.lag || 0; livePads.status();
    };
    if (this.ctx.audioWorklet) {
      this.ctx.audioWorklet.addModule("chop-worklet.js").then(() => {
        const node = new AudioWorkletNode(this.ctx, "needle-chop", { outputChannelCount: [2] });
        this.pre.disconnect();
        this.pre.connect(node);
        node.connect(this.vizAnalyser);
        node.port.onmessage = (e) => onChopMessage(e.data);
        this.chop = node;
        this.setChops(screw.chops);
      }).catch(() => this.chopFallback(onChopMessage));
    } else this.chopFallback(onChopMessage);
  },
  /** Browsers only allow audio-thread code on https pages. On the plain http home address (192.168.x.x),
      run the same chopper on the page instead: a little more delay, same chops. */
  chopFallback(onMessage) {
    if (this.chop || !this.ctx.createScriptProcessor) return;
    const start = () => {
      if (typeof Chopper === "undefined") return;
      const ctx = this.ctx, chopper = new Chopper(ctx.sampleRate);
      let amount = "off", lastReport = 0, frames = 0;
      const sp = ctx.createScriptProcessor(2048, 2, 2);
      sp.onaudioprocess = (e) => {
        const inp = e.inputBuffer, out = e.outputBuffer, n = inp.length, chans = [];
        for (let c = 0; c < out.numberOfChannels; c++) { const o = out.getChannelData(c); o.set(inp.getChannelData(Math.min(c, inp.numberOfChannels - 1))); chans.push(o); }
        if (amount !== "off" || chopper.active || chopper.lag > 0 || chopper.frozen || chopper.scr) {
          // same 128-sample steps as the audio thread, so beats and cuts line up the same way
          for (let i = 0; i < n; i += 128) chopper.process(chans.map((ch) => ch.subarray(i, i + 128)), Math.min(128, n - i), amount);
        }
        frames += n;
        if (chopper.changed || frames - lastReport > ctx.sampleRate) { chopper.changed = false; lastReport = frames; onMessage(chopStats(chopper)); }
      };
      this.pre.disconnect();
      this.pre.connect(sp);
      sp.connect(this.vizAnalyser);
      const reply = (m) => setTimeout(() => onMessage(m));
      this.chop = { node: sp, port: { postMessage: (d) => handleChopMessage(chopper, d, reply, (a) => { amount = a; }) } };
      this.setChops(screw.chops);
    };
    if (typeof Chopper !== "undefined") return start();
    const sc = document.createElement("script");
    sc.src = "chop-worklet.js";
    sc.onload = start;
    document.head.appendChild(sc);
  },
  setChops(amount) { if (this.chop) this.chop.port.postMessage({ amount }); },
  lag: 0,                // seconds you're behind the song because of chops (they push the rest of the song back)
  resetChops() { this.lag = 0; if (this.chop) this.chop.port.postMessage({ reset: true }); },
  /** Paused: the chopper holds its place instead of playing on from memory. */
  holdChops(paused) { if (this.chop) this.chop.port.postMessage({ pause: paused }); },
  /** Live mode: play a chop move now. */
  trigger(move, hold) { if (this.chop) this.chop.port.postMessage({ trigger: move, hold: !!hold }); },
  release() { if (this.chop) this.chop.port.postMessage({ release: true }); },
  /** The turntable: "down" (hand on the record), "move" (turned by `offset` seconds since), "up" (let go). */
  /** Tape stop / start (the deck's Start/Stop button). */
  tapeStop(stop) { if (this.chop) this.chop.port.postMessage({ tape: stop ? "stop" : "start" }); },
  scratch(what, offset, speed) { if (this.chop) this.chop.port.postMessage({ scratch: what, offset, speed }); },
  connect(el) {
    this.ensure();
    if (!this.ctx) return false;
    try { this.ctx.createMediaElementSource(el).connect(this.filters[0]); return true; } catch { return false; }
  },
  apply() {
    if (!this.ctx) return;
    const on = eq.enabled;
    this.filters.forEach((b, i) => b.gain.setTargetAtTime(on ? eq.gains[i] : 0, this.ctx.currentTime, 0.02));
    const maxBoost = Math.max(0, ...eq.gains);
    let g = Math.pow(10, (on ? eq.preamp : 0) / 20);
    if (on && eq.guard) g *= Math.pow(10, (-maxBoost * 0.6) / 20);
    this.pre.gain.setTargetAtTime(g, this.ctx.currentTime, 0.02);
  },
  /** 0..1 levels, log-spaced like hearing. */
  spectrum(bins) {
    const out = new Array(bins).fill(0);
    if (!this.analyser || !player.playing) return out;
    this.analyser.getFloatFrequencyData(this.freqData);
    const fs = this.ctx.sampleRate, n = this.freqData.length, binHz = fs / 2 / n;
    for (let b = 0; b < bins; b++) {
      const f0 = 25 * Math.pow(20000 / 25, b / bins), f1 = 25 * Math.pow(20000 / 25, (b + 1) / bins);
      const i0 = Math.max(1, Math.floor(f0 / binHz)), i1 = Math.max(i0 + 1, Math.min(n, Math.floor(f1 / binHz)));
      let peak = -200;
      for (let i = i0; i < i1; i++) peak = Math.max(peak, this.freqData[i]);
      out[b] = clamp((peak + 90) / 70, 0, 1);
    }
    return out;
  },
};

/* RBJ "audio EQ cookbook" math, used to draw the curve. */
function biquad(i, gain, fs = 44100) {
  const f = Math.min(FREQS[i], fs * 0.45), A = Math.pow(10, gain / 40), w0 = 2 * Math.PI * f / fs;
  const cw = Math.cos(w0), sw = Math.sin(w0);
  let b0, b1, b2, a0, a1, a2;
  if (i === 0 || i === 9) {
    const sa = 2 * Math.sqrt(A) * (sw / 2 * Math.SQRT2);
    if (i === 0) {
      b0 = A * ((A + 1) - (A - 1) * cw + sa); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - sa);
      a0 = (A + 1) + (A - 1) * cw + sa; a1 = -2 * ((A - 1) + (A + 1) * cw); a2 = (A + 1) + (A - 1) * cw - sa;
    } else {
      b0 = A * ((A + 1) + (A - 1) * cw + sa); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - sa);
      a0 = (A + 1) - (A - 1) * cw + sa; a1 = 2 * ((A - 1) - (A + 1) * cw); a2 = (A + 1) - (A - 1) * cw - sa;
    }
  } else {
    const alpha = sw / (2 * 1.41);
    b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A;
  }
  return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0];
}
function responseDB(freq, gains, fs = 44100) {
  let total = 0;
  gains.forEach((g, i) => {
    if (!g) return;
    const [b0, b1, b2, a1, a2] = biquad(i, g, fs);
    const w = 2 * Math.PI * freq / fs, c1 = Math.cos(w), s1 = Math.sin(w), c2 = Math.cos(2 * w), s2 = Math.sin(2 * w);
    const nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2), dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2);
    total += 10 * Math.log10(Math.max((nr * nr + ni * ni) / Math.max(dr * dr + di * di, 1e-12), 1e-18));
  });
  return total;
}

/* ============================================================
   Player
   ============================================================ */
const player = {
  queue: [], original: [], i: 0, el: null, next: null, nextIndex: -1,
  playing: false, shuffled: false, repeat: "off", scrobbled: false,

  get current() { return this.queue[this.i]; },

  makeEl(t) {
    const a = new Audio();
    a.preload = "auto";
    a.src = streamURL(t);
    a.routed = screw.routed ? audio.connect(a) : false;
    screw.applyTo(a);
    return a;
  },

  play(tracks, start = 0, shuffle = false) {
    if (!tracks.length) return;
    audio.ensure();
    this.original = tracks.slice();
    if (shuffle) {
      const rest = tracks.slice();
      const first = rest.splice(start || Math.floor(Math.random() * rest.length), 1)[0];
      for (let k = rest.length - 1; k > 0; k--) { const j = Math.floor(Math.random() * (k + 1)); [rest[k], rest[j]] = [rest[j], rest[k]]; }
      this.queue = [first, ...rest];
      this.i = 0;
    } else {
      this.queue = tracks.slice();
      this.i = clamp(start, 0, tracks.length - 1);
    }
    this.shuffled = shuffle;
    this.start();
  },

  start(at = 0) {
    const t = this.current;
    if (!t) return;
    this.stopTail();
    this.drop(this.el);
    if (this.next && this.nextIndex === this.i && this.next.routed === screw.routed) {
      this.el = this.next;
    } else {
      this.drop(this.next);
      this.el = this.makeEl(t);
    }
    this.next = null; this.nextIndex = -1;
    const el = this.el;
    this.scrobbled = false;
    el.ontimeupdate = () => { if (el === this.el) this.onTime(); };
    el.onended = () => { if (el === this.el) this.ended(); };
    el.onplay = () => { if (el === this.el) audio.holdChops(false); };
    el.onplaying = () => { if (el === this.el) { this.playing = true; ui.update(); } };
    el.onpause = () => { if (el === this.el && !el.ended) { audio.holdChops(true); this.playing = false; ui.update(); } };
    el.oncanplaythrough = () => { if (el === this.el) this.preload(); };
    el.onerror = () => {
      if (el !== this.el) return;
      toast(`Couldn't play “${t.title}”.`);
      setTimeout(() => { if (el === this.el) this.skip(); }, 1200);
    };
    if (at) el.addEventListener("loadedmetadata", () => { el.currentTime = at; }, { once: true });
    this.playing = true;
    el.play().catch(() => { this.playing = false; ui.update(); });
    this.session();
    this.resumeAt = 0;
    audio.resetChops();
    if (window.onTrackStart) onTrackStart(t);
    ui.trackChanged();
  },
  /** Plays the restored song from where you left off (after reopening the app). */
  resume() {
    if (this.el) { if (this.el.paused) this.toggle(); return; }
    if (!this.current) return;
    audio.ensure();
    this.start(this.resumeAt || 0);
  },

  drop(el) { if (el) { el.onplay = el.onpause = el.onended = el.ontimeupdate = el.onerror = null; el.pause(); el.removeAttribute("src"); el.load(); } },

  nextIdx(wrap) {
    if (this.i + 1 < this.queue.length) return this.i + 1;
    return (this.repeat === "all" || (wrap && this.repeat !== "off")) && this.queue.length ? 0 : -1;
  },

  preload() {
    const ni = this.nextIdx(false);
    if (ni < 0 || this.repeat === "one" || this.nextIndex === ni) return;
    this.drop(this.next);
    this.next = this.makeEl(this.queue[ni]);
    this.nextIndex = ni;
  },

  ended(afterTail) {
    // chops pushed the song back: play the rest of it before moving on
    const tail = screw.routed && !afterTail ? audio.lag : 0;
    if (tail > 0.05 && !this.tailTimer) {
      const el = this.el, until = performance.now() + tail * 1000;
      this.tailUntil = until;
      const tick = setInterval(() => ui.progress(), 250);
      this.tailTimer = setTimeout(() => {
        clearInterval(tick); this.tailTimer = 0; this.tailUntil = 0;
        if (el === this.el && this.playing) this.ended(true);
      }, tail * 1000);
      this.tailTick = tick;
      return;
    }
    if (this.repeat === "one") { audio.resetChops(); this.el.currentTime = 0; this.el.play(); return; }
    const ni = this.nextIdx(false);
    if (ni < 0) { this.playing = false; this.el.currentTime = 0; ui.update(); return; }
    this.i = ni;
    this.start();
  },

  stopTail() {
    if (this.tailTimer) { clearTimeout(this.tailTimer); clearInterval(this.tailTick); this.tailTimer = 0; this.tailUntil = 0; }
  },
  toggle() {
    if (!this.el) return this.resume();
    if (this.tailTimer) {      // pausing during the last bit after the song "ended": pick it back up from there later
      const left = Math.max(0, this.tailUntil - performance.now()) / 1000;
      this.stopTail();
      audio.holdChops(true); this.playing = false; ui.update();
      this.tailLeft = left;
      return;
    }
    if (this.tailLeft) {
      const left = this.tailLeft; this.tailLeft = 0;
      audio.holdChops(false); this.playing = true; audio.lag = left; ui.update();
      this.ended();     // waits out what's left of it
      return;
    }
    audio.ensure();
    if (this.el.paused) { this.el.play().catch(() => {}); this.playing = true; }
    else { this.el.pause(); this.playing = false; }
    ui.update();
  },
  skip() { const ni = this.nextIdx(true); if (ni >= 0) { this.i = ni; this.start(); } },
  prev() {
    if (!this.el) return;
    if (this.time() > 3 || this.i === 0) { this.stopTail(); this.tailLeft = 0; audio.resetChops(); this.el.currentTime = 0; if (this.el.paused) this.el.play().catch(() => {}); this.playing = true; ui.update(); }
    else { this.i -= 1; this.start(); }
  },
  seek(s) {
    this.stopTail(); this.tailLeft = 0;
    audio.resetChops();
    if (this.el) this.el.currentTime = clamp(s, 0, (this.duration() || 0) - 0.5);
    else { this.resumeAt = Math.max(0, s); ui.progress(); }
  },
  /** Where you are in the song as you hear it (chops push the song back a little each time). */
  time() {
    if (!this.el) return this.resumeAt || 0;
    const behind = screw.routed ? audio.lag * screw.rate : 0;
    if (this.tailUntil) return Math.max(0, this.duration() - Math.max(0, this.tailUntil - performance.now()) / 1000 * screw.rate);
    if (this.tailLeft) return Math.max(0, this.duration() - this.tailLeft * screw.rate);
    return Math.max(0, this.el.currentTime - behind);
  },
  duration() {
    const d = this.el?.duration;
    return isFinite(d) && d > 0 ? d : (this.current?.duration || 0);
  },

  toggleShuffle() {
    const cur = this.current;
    if (!cur) return;
    const queued = this.queue.slice(this.i + 1, this.i + 1 + this.queuedCount());
    if (this.shuffled) {
      const base = this.original.slice();
      const at = Math.max(0, base.findIndex((t) => t.id === cur.id));
      base.splice(at, 1, cur, ...queued);
      this.queue = base;
      this.i = at;
    } else {
      this.original = this.queue.filter((t) => !t.queued);
      const rest = this.queue.filter((t, k) => k > this.i + queued.length || (k < this.i && !t.queued));
      for (let k = rest.length - 1; k > 0; k--) { const j = Math.floor(Math.random() * (k + 1)); [rest[k], rest[j]] = [rest[j], rest[k]]; }
      this.queue = [cur, ...queued, ...rest];
      this.i = 0;
    }
    this.shuffled = !this.shuffled;
    this.resetNext();
    ui.update();
  },
  cycleRepeat() {
    this.repeat = { off: "all", all: "one", one: "off" }[this.repeat];
    this.resetNext();
    ui.update();
  },
  /** Songs you queued sit right after the current one ("Next in Queue"), ahead of the rest of the album or playlist. */
  queuedCount() { let n = 0; while (this.queue[this.i + 1 + n]?.queued) n++; return n; },
  playNext(tracks) {
    if (!this.queue.length) return this.play(tracks);
    this.queue.splice(this.i + 1, 0, ...tracks.map((t) => ({ ...t, queued: true })));
    this.resetNext(); toast(tracks.length > 1 ? `Playing ${tracks.length} songs next` : "Playing next");
  },
  addToQueue(tracks) {
    if (!this.queue.length) return this.play(tracks);
    this.queue.splice(this.i + 1 + this.queuedCount(), 0, ...tracks.map((t) => ({ ...t, queued: true })));
    this.resetNext(); toast(tracks.length > 1 ? `Added ${tracks.length} songs to queue` : "Added to queue");
  },
  resetNext() { this.drop(this.next); this.next = null; this.nextIndex = -1; if (this.el && this.el.readyState >= 3) this.preload(); },

  /** Re-creates the current song's audio so turning the EQ on/off takes effect right away. */
  reroute() {
    if (!this.el || this.el.routed === screw.routed) return;
    const at = this.time(), wasPlaying = !this.el.paused;
    this.start(at);
    if (!wasPlaying) setTimeout(() => this.el && this.el.pause(), 50);
  },

  onTime() {
    ui.progress();
    const t = this.current, d = this.duration();
    if (!this.scrobbled && t && !t.local && d > 0 && this.time() > Math.min(d * 0.5, 240)) {
      this.scrobbled = true;
      lib.scrobble(t.id);
    }
    if ("mediaSession" in navigator && navigator.mediaSession.setPositionState && d > 0) {
      try { navigator.mediaSession.setPositionState({ duration: d, position: Math.min(this.time(), d), playbackRate: 1 }); } catch { /* ignore */ }
    }
  },

  session() {
    if (!("mediaSession" in navigator)) return;
    const t = this.current;
    navigator.mediaSession.metadata = new MediaMetadata({
      title: t.title, artist: t.artist, album: t.album,
      artwork: t.coverArt ? [{ src: new URL(cover(t.coverArt, 900), location.href).href, sizes: "900x900", type: "image/jpeg" }] : [],
    });
    const ms = navigator.mediaSession;
    ms.setActionHandler("play", () => this.toggle());
    ms.setActionHandler("pause", () => this.toggle());
    ms.setActionHandler("nexttrack", () => this.skip());
    ms.setActionHandler("previoustrack", () => this.prev());
    try { ms.setActionHandler("seekto", (e) => this.seek(e.seekTime)); } catch { /* not supported */ }
  },

  star(on) {
    const t = this.current;
    if (!t || t.local) return;
    setStarred([t], on, true);
  },
};

/* ============================================================
   Album colors
   ============================================================ */
const paletteCache = new Map();
function hsv(r, g, b) {
  r /= 255; g /= 255; b /= 255;
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn;
  let h = 0;
  if (d) h = mx === r ? ((g - b) / d) % 6 : mx === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return [((h * 60) + 360) % 360, mx ? d / mx : 0, mx];
}
const css = (h, s, v) => {
  const f = (n) => { const k = (n + h / 60) % 6; return Math.round(255 * (v - v * s * Math.max(0, Math.min(k, 4 - k, 1)))); };
  return `rgb(${f(5)},${f(3)},${f(1)})`;
};
function palette(coverId) {
  if (!coverId) return Promise.resolve({ top: "#33294d", bottom: "#121019", accent: "#f28c66" });
  if (paletteCache.has(coverId)) return paletteCache.get(coverId);
  const p = new Promise((resolve) => {
    const img = new Image();
    img.onload = () => {
      try {
        const c = document.createElement("canvas"); c.width = c.height = 8;
        const g = c.getContext("2d"); g.drawImage(img, 0, 0, 8, 8);
        const d = g.getImageData(0, 0, 8, 8).data;
        const avg = (y0, y1) => { let r = 0, gg = 0, b = 0, n = 0; for (let y = y0; y < y1; y++) for (let x = 0; x < 8; x++) { const i = (y * 8 + x) * 4; r += d[i]; gg += d[i + 1]; b += d[i + 2]; n++; } return hsv(r / n, gg / n, b / n); };
        const [th, ts, tv] = avg(0, 4), [bh, bs, bv] = avg(4, 8);
        let best = [0, 0, 1], score = -1;
        for (let i = 0; i < d.length; i += 4) { const h = hsv(d[i], d[i + 1], d[i + 2]); const sc = h[1] * (0.4 + h[2]); if (sc > score) { score = sc; best = h; } }
        resolve({ top: css(th, ts, Math.min(tv, 0.55)), bottom: css(bh, bs, Math.min(bv, 0.25)), accent: css(best[0], Math.max(best[1], 0.45), Math.max(best[2], 0.78)) });
      } catch { resolve({ top: "#33294d", bottom: "#121019", accent: "#f28c66" }); }
    };
    img.onerror = () => resolve({ top: "#33294d", bottom: "#121019", accent: "#f28c66" });
    img.src = cover(coverId, 160);
  });
  paletteCache.set(coverId, p);
  return p;
}

/* ============================================================
   UI: mini player, Now Playing, menus
   ============================================================ */
const ui = {
  trackChanged() {
    const t = player.current;
    $("#mini").hidden = !t;
    if (!t) return;
    const art = cover(t.coverArt, 900);
    $("#mini .art").src = cover(t.coverArt, 160);
    $("#mini b").textContent = t.title;
    $("#mini span").textContent = t.artist;
    $(".np-art").src = art;
    softBackdrop(t.coverArt);
    $("#np-title").textContent = t.title;
    const npa = $("#np-artist");
    npa.textContent = t.artist;
    npa.disabled = !t.artistId && !t.artist;
    npa.setAttribute("aria-label", `${t.artist}. Go to artist`);
    $("#np-album").textContent = t.album;
    if (window.lyrics) lyrics.trackChanged(t);
    palette(t.coverArt).then((p) => {
      if (player.current !== t) return;
      const r = document.documentElement.style;
      r.setProperty("--np-top", p.top);
      r.setProperty("--np-bottom", p.bottom);
      r.setProperty("--np-accent", p.accent);
      if (window.Viz) Viz.setColor(p.accent);
      if (window.onAlbumColor) onAlbumColor(p.accent);
    });
    this.update();
    $$(".row[data-id]").forEach((r) => r.classList.toggle("current", r.dataset.id === t.id));
  },
  update() {
    const t = player.current;
    const playIcon = player.playing ? "pause" : "play";
    $("#mini-play use").setAttribute("href", `#i-${playIcon}`);
    $("#np-play use").setAttribute("href", `#i-${playIcon}`);
    $("#np").classList.toggle("paused", !player.playing);
    document.body.classList.toggle("playing", player.playing);
    $("#np-shuffle").classList.toggle("on", player.shuffled);
    $("#np-repeat").classList.toggle("on", player.repeat !== "off");
    $("#np-repeat use").setAttribute("href", player.repeat === "one" ? "#i-repeat1" : "#i-repeat");
    const heart = $("#np-heart");
    heart.hidden = !t || !!t.local;
    heart.classList.toggle("on", !!t?.starred);
    $("#np-heart use").setAttribute("href", t?.starred ? "#i-heartfill" : "#i-heart");
    livePads.show(screw.chops === "live");
    if (typeof turntable !== "undefined") turntable.show(screw.chops === "live" && !!player.current);
    const sc = $("#np-screw"), lab = screw.label();
    sc.classList.toggle("on", !!lab);
    $("span", sc).textContent = lab;
    const chip = $("#np-eq");
    chip.classList.toggle("off", !eq.enabled);
    $("span", chip).textContent = eq.enabled ? eq.preset : "EQ Off";
    if (!$("#queue").hidden) renderQueue();
    this.progress();
  },
  progress() {
    const d = player.duration(), c = player.time();
    const frac = d ? clamp(c / d, 0, 1) : 0;
    $("#mini .prog i").style.width = `${frac * 100}%`;
    if ($("#np").hidden || scrubbing) return;
    const seek = $("#np-seek");
    seek.value = Math.round(frac * 1000);
    seek.style.setProperty("--p", `${frac * 100}%`);
    $("#np-cur").textContent = fmt(c);
    $("#np-left").textContent = "-" + fmt(Math.max(0, d - c));
  },
};

let scrubbing = false;
function openNP() {
  if (!player.current) return;
  const np = $("#np");
  np.hidden = false;
  np.classList.add("closing");
  requestAnimationFrame(() => requestAnimationFrame(() => np.classList.remove("closing")));
  ui.update();
  glowLoop();
  if (window.vizUI) vizUI.npOpened();
  if (window.lyrics) lyrics.npOpened();
}
function closeNP() {
  const np = $("#np");
  if (window.vizUI) vizUI.npClosed();
  if (window.lyrics) lyrics.npClosed();
  np.classList.add("closing");
  setTimeout(() => { np.hidden = true; np.classList.remove("closing"); np.style.transform = ""; }, 330);
}

function glowLoop() {
  const c = $("#np canvas.glow");
  const draw = () => {
    if ($("#np").hidden) return;
    if (document.body.classList.contains("viz-active")) { requestAnimationFrame(draw); return; }   // visualizer is on instead
    const dpr = window.devicePixelRatio || 1, w = c.clientWidth, h = c.clientHeight;
    if (c.width !== w * dpr) { c.width = w * dpr; c.height = h * dpr; }
    const g = c.getContext("2d");
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, w, h);
    const bins = audio.spectrum(48), bw = w / bins.length;
    const accent = getComputedStyle(document.documentElement).getPropertyValue("--np-accent").trim() || "#f28c66";
    bins.forEach((v, i) => {
      const bh = v * h;
      const grad = g.createLinearGradient(0, h - bh, 0, h);
      grad.addColorStop(0, "rgba(0,0,0,0)");
      grad.addColorStop(1, accent);
      g.fillStyle = grad;
      g.fillRect(i * bw + 1, h - bh, bw - 2, bh);
    });
    requestAnimationFrame(draw);
  };
  requestAnimationFrame(draw);
}

/** Favorites a song (or un-favorites it) everywhere it shows up: the queue, this screen, Now Playing. */
function setStarred(tracks, on, quiet) {
  const ids = new Set(tracks.filter((t) => !t.local).map((t) => t.id));
  if (!ids.size) return;
  for (const list of [player.queue, player.original, screenTracks]) for (const t of list) if (ids.has(t.id)) t.starred = on;
  for (const t of tracks) t.starred = on;
  Promise.all([...ids].map((id) => lib.star(id, on))).catch(() => toast("Couldn't update favorites."));
  if (!quiet) toast(on ? (ids.size > 1 ? `Added ${ids.size} songs to Favorites` : "Added to Favorites") : "Removed from Favorites");
  document.querySelectorAll(".row[data-id]").forEach((r) => {
    if (!ids.has(r.dataset.id)) return;
    r.classList.toggle("starred", on);
    const h = r.querySelector("svg.fav");
    if (on && !h) r.querySelector(".dur")?.insertAdjacentHTML("beforebegin", `<svg class="i fav" aria-label="Favorite"><use href="#i-heartfill"/></svg>`);
    if (!on && h) h.remove();
  });
  ui.update();
}

/** menuContext: what screen the menu was opened from, so it can offer "Remove from This Playlist". */
let menuContext = null;
function showMenu(title, tracks, ctx = null) {
  const m = $("#menu");
  const real = tracks.filter((t) => !t.local);
  const allStarred = real.length && real.every((t) => t.starred);
  m.innerHTML = `<div class="panel">
    <p>${esc(title)}</p>
    <button data-act="next">${icon("next-up")}Play Next</button>
    <button data-act="queue">${icon("append")}Add to Queue</button>
    ${real.length ? `<button data-act="playlist">${icon("plus")}Add to Playlist…</button>` : ""}
    ${real.length ? `<button data-act="star">${icon(allStarred ? "heartfill" : "heart")}${allStarred ? "Remove from Favorites" : "Add to Favorites"}</button>` : ""}
    ${ctx?.playlistId && ctx.index != null ? `<button data-act="unlist">${icon("minus")}Remove from This Playlist</button>` : ""}
    ${real.length ? `<button data-act="delete" class="danger">${icon("x")}Delete from Library…</button>` : ""}
    ${tracks.length === 1 && tracks[0].albumId ? `<button data-act="album">${icon("album")}Go to Album</button>` : ""}
    ${tracks.length === 1 && tracks[0].artistId ? `<button data-act="artist">${icon("mic")}Go to Artist</button>` : ""}
  </div>`;
  m.hidden = false;
  m.onclick = (e) => {
    const act = e.target.closest("button")?.dataset.act;
    if (act === "playlist") return showPlaylistPicker(real);
    if (act === "delete") return confirmDelete(real, tracks.length === 1 ? `“${tracks[0].title}”` : `${real.length} songs`);
    m.hidden = true;
    if (act === "next") player.playNext(tracks);
    if (act === "queue") player.addToQueue(tracks);
    if (act === "star") setStarred(real, !allStarred);
    if (act === "unlist") removeFromPlaylist(ctx.playlistId, ctx.index);
    if (act === "album") { closeNP(); location.hash = `#/album/${tracks[0].albumId}`; }
    if (act === "artist") { closeNP(); location.hash = `#/artist/${tracks[0].artistId}`; }
  };
}

/** Deletes songs' files from the NAS (the helper moves them to a trash folder there, so it can be undone). */
function confirmDelete(tracks, what, after) {
  const m = $("#menu");
  m.hidden = false;
  m.innerHTML = `<div class="panel"><p>Delete ${esc(what)} from your library?</p>
    <p class="note" style="white-space:normal">The ${tracks.length === 1 ? "file is" : "files are"} moved to the trash folder on your NAS (helper-data/trash), so you can get ${tracks.length === 1 ? "it" : "them"} back if you need to.</p>
    <button data-del="yes" class="danger">${icon("x")}Delete</button><button data-del="no">Cancel</button></div>`;
  m.onclick = async (e) => {
    const b = e.target.closest("[data-del]");
    if (e.target !== m && !b) return;
    m.hidden = true;
    if (!b || b.dataset.del !== "yes") return;
    try {
      const r = await importer.helper("delete", { songIds: tracks.map((t) => t.id) });
      const ids = new Set(tracks.map((t) => t.id));
      document.querySelectorAll(".row[data-id]").forEach((row) => { if (ids.has(row.dataset.id)) row.remove(); });
      toast(r.deleted ? `Deleted ${r.deleted === 1 ? "it" : `${r.deleted} songs`}` + (r.missing.length ? ` · couldn't find ${r.missing.length}` : "")
                      : `Couldn't find the file${tracks.length === 1 ? "" : "s"} on the NAS`);
      if (r.deleted && after) after();
    } catch (err) { toast(err.message); }
  };
}

async function removeFromPlaylist(id, index) {
  try {
    await lib.removeFromPlaylist(id, [index]);
    toast("Removed from playlist");
    if (location.hash === `#/playlist/${id}`) route();
  } catch (e) { toast(`Couldn't change the playlist: ${e.message}`); }
}

/** "Add to Playlist": pick one of your playlists, or make a new one with these songs in it. */
async function showPlaylistPicker(tracks) {
  const m = $("#menu");
  const ids = tracks.map((t) => t.id);
  const what = tracks.length === 1 ? `“${tracks[0].title}”` : `${tracks.length} songs`;
  m.hidden = false;
  m.innerHTML = `<div class="panel picker"><p>Add ${esc(what)} to…</p>
    <form id="pl-new" class="pl-new"><label class="field">${icon("plus")}<input id="pl-name" placeholder="New playlist name" autocomplete="off" maxlength="120"></label><button class="pill primary" type="submit">Create</button></form>
    <div id="pl-list"><p class="note">Loading your playlists…</p></div></div>`;
  m.onclick = (e) => {
    if (e.target === m) { m.hidden = true; return; }
    const b = e.target.closest("[data-pl]");
    if (!b) return;
    m.hidden = true;
    lib.addToPlaylist(b.dataset.pl, ids).then(() => toast(`Added to ${b.dataset.name}`))
      .catch((err) => toast(`Couldn't add it: ${err.message}`));
  };
  $("#pl-new").onsubmit = (e) => {
    e.preventDefault();
    const name = $("#pl-name").value.trim();
    if (!name) { $("#pl-name").focus(); return; }
    m.hidden = true;
    lib.createPlaylist(name, ids).then(() => { toast(`Made “${name}”`); if (location.hash === "#/playlists") route(); })
      .catch((err) => toast(`Couldn't make the playlist: ${err.message}`));
  };
  try {
    const lists = (await lib.playlists()).filter((p) => !p.readonly && (!p.owner || p.owner === cfg.user));
    if (m.hidden || !$("#pl-list")) return;
    $("#pl-list").innerHTML = lists.length ? lists.map((p) => `<button data-pl="${esc(p.id)}" data-name="${esc(p.name)}">
        <img class="art" loading="lazy" src="${cover(p.coverArt || p.id, 160)}" alt=""><span class="pl-meta"><b>${esc(p.name)}</b><small>${p.songCount || 0} songs</small></span></button>`).join("")
      : `<p class="note">No playlists yet. Name one above to make it.</p>`;
  } catch (err) { if ($("#pl-list")) $("#pl-list").innerHTML = `<p class="note">Couldn't load playlists: ${esc(err.message)}</p>`; }
}

function newPlaylistSheet() {
  const m = $("#menu");
  m.hidden = false;
  m.innerHTML = `<div class="panel picker"><p>New playlist</p>
    <form id="pl-new" class="pl-new"><label class="field">${icon("playlist")}<input id="pl-name" placeholder="Name it" autocomplete="off" maxlength="120"></label><button class="pill primary" type="submit">Create</button></form>
    <p class="note">Add songs with ••• → Add to Playlist.</p></div>`;
  m.onclick = (e) => { if (e.target === m) m.hidden = true; };
  setTimeout(() => $("#pl-name")?.focus(), 50);
  $("#pl-new").onsubmit = async (e) => {
    e.preventDefault();
    const name = $("#pl-name").value.trim();
    if (!name) return;
    m.hidden = true;
    try {
      const p = await lib.createPlaylist(name, []);
      toast(`Made “${name}”`);
      if (p?.id) location.hash = `#/playlist/${p.id}`; else route();
    } catch (err) { toast(`Couldn't make the playlist: ${err.message}`); }
  };
}

/* ---------- swipe a song row: right = add to queue, left = favorite (like Spotify) ---------- */
const swipe = {
  start(e) {
    const row = e.target.closest(".row[data-index]");
    if (!row || +row.dataset.index < 0 || e.target.closest("button.more")) return;
    if (e.pointerType === "mouse" && e.button !== 0) return;
    this.row = row; this.x0 = e.clientX; this.y0 = e.clientY; this.dx = 0; this.on = false; this.armed = false; this.id = e.pointerId;
  },
  move(e) {
    if (!this.row || e.pointerId !== this.id) return;
    const dx = e.clientX - this.x0, dy = e.clientY - this.y0;
    if (!this.on) {
      if (Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx)) { this.row = null; return; }   // scrolling
      if (Math.abs(dx) < 12) return;
      this.on = true;
      this.row.classList.add("swiping");
      try { this.row.setPointerCapture(e.pointerId); } catch { /* fine */ }
    }
    e.preventDefault();
    const w = this.row.offsetWidth, lim = w * 0.45;
    this.dx = Math.max(-lim, Math.min(lim, dx * (Math.abs(dx) > lim * 0.8 ? 0.6 : 1)));
    const t = screenTracks[+this.row.dataset.index];
    const fav = t?.starred;
    this.row.style.setProperty("--dx", `${this.dx}px`);
    this.row.dataset.swipe = this.dx > 0 ? "queue" : "fav";
    this.row.dataset.swipeLabel = this.dx > 0 ? "Add to Queue" : fav ? "Unfavorite" : "Favorite";
    const armed = Math.abs(this.dx) > Math.min(90, w * 0.25);
    if (armed !== this.armed) { this.armed = armed; this.row.classList.toggle("armed", armed); if (armed && navigator.vibrate) navigator.vibrate(8); }
  },
  end(e) {
    const row = this.row;
    if (!row || e.pointerId !== this.id) return;
    this.row = null;
    if (!this.on) return;
    this.suppressClick = true; setTimeout(() => (this.suppressClick = false), 50);
    row.classList.remove("swiping", "armed");
    row.style.setProperty("--dx", "0px");
    if (!this.armed || e.type === "pointercancel") return;
    const t = screenTracks[+row.dataset.index];
    if (!t) return;
    if (this.dx > 0) player.addToQueue([t]);
    else setStarred([t], !t.starred);
  },
};

/* ============================================================
   Equalizer sheet
   ============================================================ */
let activeBand = -1;
function openEQ() {
  const s = $("#eq");
  const tint = getComputedStyle(document.documentElement).getPropertyValue("--np-accent").trim() || "#6ee8d9";
  s.style.setProperty("--tint", tint);
  s.hidden = false;
  renderEQ();
  eqLoop();
}
function renderEQ() {
  const s = $("#eq");
  const prePct = ((eq.preamp + 12) / 18) * 100;
  s.classList.toggle("eq-off", !eq.enabled);
  s.innerHTML = `
    <div class="sheet-head">
      <button class="switch ${eq.enabled ? "on" : ""}" id="eq-power" aria-label="Equalizer on or off"></button>
      <h3>Equalizer</h3>
      <button class="done" id="eq-done">Done</button>
    </div>
    <canvas id="eq-graph"></canvas>
    <div class="band-values">${eq.gains.map((g, i) => `<div data-band="${i}"><b class="${g ? "set" : ""}">${g > 0 ? "+" : ""}${Math.round(g)}</b><span>${LABELS[i]}</span></div>`).join("")}</div>
    <div class="section"><div class="section-head"><h2 class="h2" style="font-size:18px">Presets</h2></div>
      <div class="presets">${allPresets().map((p) => `<button class="chip ${eq.preset === p.name ? "on" : ""}" data-preset="${esc(p.name)}">${esc(p.name)}</button>`).join("")}
        <button class="chip dashed" id="eq-save">+ Save</button></div></div>
    <div class="eq-card">
      <div class="line"><b>Preamp</b><span class="muted">${eq.preamp > 0 ? "+" : ""}${eq.preamp.toFixed(1)} dB</span></div>
      <input id="eq-pre" type="range" min="-12" max="6" step="0.5" value="${eq.preamp}" style="--p:${prePct}%">
      <div class="line"><div><b>Prevent distortion</b><small>Lowers the volume a little when you boost, so loud parts don't crackle.</small></div>
        <button class="switch ${eq.guard ? "on" : ""}" id="eq-guard" aria-label="Prevent distortion"></button></div>
    </div>
    <p class="bg-tip">Tip: on iPhone, music with the EQ on may stop when you lock the screen. Turn the EQ off for locked listening.</p>`;
  $("#eq-done").onclick = () => { s.hidden = true; };
  $("#eq-power").onclick = () => { eq.enabled = !eq.enabled; saveEQ(); audio.apply(); player.reroute(); renderEQ(); ui.update(); };
  $("#eq-guard").onclick = () => { eq.guard = !eq.guard; saveEQ(); audio.apply(); renderEQ(); };
  $("#eq-pre").oninput = (e) => {
    eq.preamp = +e.target.value; saveEQ(); audio.apply();
    e.target.style.setProperty("--p", `${((eq.preamp + 12) / 18) * 100}%`);
    $(".eq-card .line .muted").textContent = `${eq.preamp > 0 ? "+" : ""}${eq.preamp.toFixed(1)} dB`;
  };
  $$("[data-preset]", s).forEach((b) => (b.onclick = () => {
    const p = allPresets().find((x) => x.name === b.dataset.preset);
    if (!p) return;
    animateTo(p.gains);
    eq.preset = p.name; saveEQ(); renderEQ(); ui.update();
  }));
  $$("[data-preset]", s).forEach((b) => b.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    const p = eq.custom.find((x) => x.name === b.dataset.preset);
    if (p && confirm(`Delete the preset “${p.name}”?`)) { eq.custom = eq.custom.filter((x) => x !== p); saveEQ(); renderEQ(); }
  }));
  $("#eq-save").onclick = () => {
    const name = (prompt("Give this sound a name") || "").trim();
    if (!name || PRESETS.some((p) => p.name === name)) return;
    eq.custom = eq.custom.filter((p) => p.name !== name).concat({ name, gains: eq.gains.slice() });
    eq.preset = name; saveEQ(); renderEQ(); ui.update();
  };
  $$(".band-values [data-band]", s).forEach((el) => el.addEventListener("dblclick", () => setGain(+el.dataset.band, 0)));
  bindGraph($("#eq-graph"));
}
function animateTo(target) {
  const from = eq.gains.slice(), t0 = performance.now();
  const step = (now) => {
    const k = Math.min(1, (now - t0) / 280), e = 1 - Math.pow(1 - k, 3);
    eq.gains = from.map((g, i) => g + (target[i] - g) * e);
    audio.apply();
    if (k < 1) requestAnimationFrame(step); else { eq.gains = target.slice(); saveEQ(); audio.apply(); refreshBandValues(); }
  };
  requestAnimationFrame(step);
}
function setGain(band, v) {
  eq.gains[band] = clamp(v, -12, 12);
  eq.preset = allPresets().find((p) => p.gains.every((g, i) => g === eq.gains[i]))?.name || "Custom";
  saveEQ(); audio.apply(); refreshBandValues();
  $$("[data-preset]").forEach((b) => b.classList.toggle("on", b.dataset.preset === eq.preset));
  ui.update();
}
function refreshBandValues() {
  $$(".band-values [data-band]").forEach((el) => {
    const i = +el.dataset.band, g = eq.gains[i], b = $("b", el);
    b.textContent = `${g > 0 ? "+" : ""}${Math.round(g)}`;
    b.className = (g ? "set " : "") + (activeBand === i ? "active" : "");
  });
}

const G = { minF: 20, maxF: 20000, maxDB: 12, pad: 26 };
const gx = (f, w) => Math.log(f / G.minF) / Math.log(G.maxF / G.minF) * w;
const gy = (db, h) => h / 2 - (db / G.maxDB) * (h / 2 - G.pad);
function bindGraph(c) {
  const pos = (e) => { const r = c.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top, r.width, r.height]; };
  c.onpointerdown = (e) => {
    c.setPointerCapture(e.pointerId);
    const [x, , w] = pos(e);
    let best = 0, dist = Infinity;
    FREQS.forEach((f, i) => { const d = Math.abs(gx(f, w) - x); if (d < dist) { dist = d; best = i; } });
    activeBand = best;
    if (navigator.vibrate) navigator.vibrate(8);
    move(e);
  };
  const move = (e) => {
    if (activeBand < 0) return;
    const [, y, , h] = pos(e);
    let v = ((h / 2 - y) / (h / 2 - G.pad)) * G.maxDB;
    v = Math.round(v * 2) / 2;
    if (Math.abs(v) < 0.6) v = 0;        // a little magnet at 0 dB
    setGain(activeBand, v);
  };
  c.onpointermove = move;
  c.onpointerup = c.onpointercancel = () => { activeBand = -1; refreshBandValues(); };
}
function eqLoop() {
  const draw = () => {
    const s = $("#eq");
    if (s.hidden) return;
    const c = $("#eq-graph");
    if (c) drawGraph(c, getComputedStyle(s).getPropertyValue("--tint").trim());
    requestAnimationFrame(draw);
  };
  requestAnimationFrame(draw);
}
function drawGraph(c, tint) {
  const dpr = window.devicePixelRatio || 1, w = c.clientWidth, h = c.clientHeight;
  if (c.width !== Math.round(w * dpr)) { c.width = Math.round(w * dpr); c.height = Math.round(h * dpr); }
  const g = c.getContext("2d");
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, w, h);
  // grid
  [-12, -6, 0, 6, 12].forEach((db) => {
    const y = gy(db, h);
    g.strokeStyle = `rgba(255,255,255,${db === 0 ? 0.22 : 0.07})`;
    g.setLineDash(db === 0 ? [] : [3, 4]);
    g.beginPath(); g.moveTo(0, y); g.lineTo(w, y); g.stroke();
    if (db) { g.fillStyle = "rgba(255,255,255,.3)"; g.font = "9px -apple-system, sans-serif"; g.fillText(`${db > 0 ? "+" : ""}${db}`, 8, y - 4); }
  });
  g.setLineDash([]);
  FREQS.forEach((f) => { const x = gx(f, w); g.strokeStyle = "rgba(255,255,255,.04)"; g.beginPath(); g.moveTo(x, 10); g.lineTo(x, h - 10); g.stroke(); });
  // live spectrum
  const bins = audio.spectrum(72), bw = w / bins.length;
  bins.forEach((v, i) => {
    if (v < 0.01) return;
    const bh = v * (h - 20);
    g.fillStyle = `rgba(255,255,255,${0.07 + v * 0.1})`;
    g.fillRect(i * bw + 0.75, h - 10 - bh, Math.max(1, bw - 1.5), bh);
  });
  // curve
  const pts = [];
  for (let i = 0; i <= 140; i++) {
    const f = G.minF * Math.pow(G.maxF / G.minF, i / 140);
    pts.push([gx(f, w), gy(clamp(responseDB(f, eq.gains), -G.maxDB * 1.3, G.maxDB * 1.3), h)]);
  }
  const path = () => { g.beginPath(); pts.forEach(([x, y], i) => (i ? g.lineTo(x, y) : g.moveTo(x, y))); };
  path(); g.lineTo(w, h / 2); g.lineTo(0, h / 2); g.closePath();
  const fill = g.createLinearGradient(0, 0, 0, h);
  fill.addColorStop(0, hexA(tint, 0.35)); fill.addColorStop(0.5, hexA(tint, 0.03)); fill.addColorStop(1, hexA(tint, 0.35));
  g.fillStyle = fill; g.fill();
  g.lineCap = g.lineJoin = "round";
  g.save(); g.filter = "blur(7px)"; g.globalAlpha = 0.8; path(); g.strokeStyle = tint; g.lineWidth = 6; g.stroke(); g.restore();
  path(); g.strokeStyle = tint; g.lineWidth = 2.5; g.stroke();
  // knobs
  FREQS.forEach((f, i) => {
    const x = gx(f, w), y = gy(eq.gains[i], h), on = activeBand === i, r = on ? 11 : 7;
    g.shadowColor = tint; g.shadowBlur = on ? 14 : 6;
    g.fillStyle = on ? tint : "#fff";
    g.beginPath(); g.arc(x, y, r, 0, Math.PI * 2); g.fill();
    g.shadowBlur = 0;
    g.strokeStyle = "rgba(0,0,0,.25)"; g.lineWidth = 1; g.stroke();
  });
}
function hexA(color, a) {
  const m = color.match(/\d+/g);
  if (color.startsWith("rgb") && m) return `rgba(${m[0]},${m[1]},${m[2]},${a})`;
  const h = color.replace("#", "");
  const n = parseInt(h.length === 3 ? h.split("").map((x) => x + x).join("") : h, 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
}

/* ============================================================
   Queue sheet
   ============================================================ */
function renderQueue() {
  const s = $("#queue");
  const up = player.queue.slice(player.i + 1);
  const nq = player.queuedCount();
  const t = player.current;
  const qrow = (x, k) => `<div class="row" data-q="${k}">
        <img class="art" loading="lazy" src="${cover(x.coverArt, 160)}" alt="">
        <div class="meta"><b>${esc(x.title)}</b><span>${esc(x.artist)}</span></div>
        <button class="more" data-remove="${k}" aria-label="Remove">${icon("x")}</button></div>`;
  const rest = up.slice(nq);
  s.innerHTML = `
    <div class="sheet-head"><span></span><h3>Queue</h3><button class="done" id="q-done">Done</button></div>
    ${t ? `<div class="disc">Now Playing</div>${trackRow(t, -1, true)}` : ""}
    ${nq ? `<div class="disc" id="q-next">Next in Queue<button class="link" id="q-clear">Clear</button></div>${up.slice(0, nq).map(qrow).join("")}` : ""}
    <div class="disc">${nq ? "Then" : "Up Next"}${player.shuffled ? " · Shuffled" : ""}</div>
    ${rest.length ? rest.map((x, k) => qrow(x, k + nq)).join("")
      : `<p class="note">${nq ? "Nothing after that." : "Nothing queued. Swipe a song right, or tap ••• on it, to add it."}</p>`}`;
  const clear = $("#q-clear");
  if (clear) clear.onclick = (e) => { e.stopPropagation(); player.queue.splice(player.i + 1, nq); player.resetNext(); renderQueue(); };
  $("#q-done").onclick = () => (s.hidden = true);
  s.onclick = (e) => {
    const rm = e.target.closest("[data-remove]");
    if (rm) { player.queue.splice(player.i + 1 + +rm.dataset.remove, 1); player.resetNext(); renderQueue(); return; }
    const row = e.target.closest("[data-q]");
    if (row) { player.i = player.i + 1 + +row.dataset.q; player.start(); renderQueue(); }
  };
}

/* ============================================================
   Screens
   ============================================================ */
const view = $("#view");
let routeToken = 0;
let screenTracks = [];       // the songs listed on the current screen, for tap-to-play

function trackRow(t, index, showArt = true, number) {
  const cur = player.current?.id === t.id;
  return `<div class="row ${cur ? "current" : ""}${t.starred ? " starred" : ""}" data-id="${esc(t.id)}" data-index="${index}" role="button" tabindex="0">
    ${showArt ? `<img class="art" loading="lazy" src="${cover(t.coverArt, 160)}" alt="">`
              : `<span class="num">${cur ? '<span class="bars"><i></i><i></i><i></i></span>' : (number ?? "")}</span>`}
    <div class="meta"><b>${esc(t.title)}</b><span>${esc(showArt ? `${t.artist} · ${t.album}` : t.artist)}</span></div>
    ${t.starred ? `<svg class="i fav" aria-label="Favorite"><use href="#i-heartfill"/></svg>` : ""}
    <span class="dur">${fmt(t.duration)}</span>
    ${index >= 0 ? `<button class="more" data-more="${index}" aria-label="More">${icon("more")}</button>` : ""}
  </div>`;
}
const albumCard = (a) => `<a class="card" href="#/album/${esc(a.id)}">
  <img class="art" loading="lazy" src="${cover(a.coverArt || a.id, 300)}" alt="">
  <b>${esc(a.name)}</b><span>${esc(a.artist || (a.year ? a.year : ""))}</span></a>`;
const playButtons = () => `<div class="pill-row"><button class="pill primary" data-play="all">${icon("play")}Play</button>
  <button class="pill" data-play="shuffle">${icon("shuffle")}Shuffle</button></div>`;
const backLink = () => `<a class="back" href="javascript:history.back()">${icon("back")}Back</a>`;
const errorBox = (e) => `<div class="empty"><b>Something went wrong</b>${esc(e.message || e)}<br><br><button class="pill" style="flex:none;display:inline-flex" onclick="route()">Try Again</button></div>`;
const loading = () => `<div class="empty">Loading…</div>`;

view.addEventListener("pointerdown", (e) => swipe.start(e));
view.addEventListener("pointermove", (e) => swipe.move(e));
view.addEventListener("pointerup", (e) => swipe.end(e));
view.addEventListener("pointercancel", (e) => swipe.end(e));
view.addEventListener("click", (e) => { if (swipe.suppressClick) { e.stopPropagation(); e.preventDefault(); } }, true);
view.addEventListener("click", (e) => {
  const more = e.target.closest("[data-more]");
  if (more) {
    e.stopPropagation();
    const t = screenTracks[+more.dataset.more];
    const pl = location.hash.match(/^#\/playlist\/(.+)$/);
    if (t) showMenu(t.title, [t], pl ? { playlistId: decodeURIComponent(pl[1]), index: +more.dataset.more } : null);
    return;
  }
  const row = e.target.closest(".row[data-index]");
  if (row && +row.dataset.index >= 0) { player.play(screenTracks, +row.dataset.index); return; }
  const pb = e.target.closest("[data-play]");
  if (pb && screenTracks.length) player.play(screenTracks, 0, pb.dataset.play === "shuffle");
});

const screens = {
  async home() {
    const hour = new Date().getHours();
    const greet = hour < 5 ? "Late night" : hour < 12 ? "Morning" : hour < 17 ? "Afternoon" : hour < 22 ? "Evening" : "Late night";
    view.innerHTML = `<p class="eyebrow-greet">${greet}</p><h1 class="title" style="margin-top:2px">Listen Now</h1>
      <button class="shuffle-card" id="shuffle-all"><span class="disc-btn">${icon("shuffle")}</span>
        <span><b>Shuffle Everything</b><span>100 random songs from your library</span></span></button>
      <div id="shelves">${loading()}</div>`;
    $("#shuffle-all").onclick = async () => {
      try { const t = await lib.random(100); player.play(t); } catch (e) { toast(e.message); }
    };
    try {
      const [recent, added, frequent, random] = await Promise.all(["recent", "newest", "frequent", "random"].map((t) => lib.albums(t, 20)));
      const shelf = (title, list) => list.length ? `<div class="section"><div class="section-head"><h2 class="h2">${title}</h2></div>
        <div class="shelf">${list.map(albumCard).join("")}</div></div>` : "";
      $("#shelves").innerHTML = shelf("Jump Back In", recent) + shelf("Recently Added", added) + shelf("On Repeat", frequent) + shelf("Rediscover", random)
        || `<div class="empty"><b>Your library is empty</b>Navidrome hasn't found any music yet. Check that it can see /volume1/Music.</div>`;
    } catch (e) { $("#shelves").innerHTML = errorBox(e); }
  },

  async library() {
    view.innerHTML = `<h1 class="title">Library</h1>
      ${[["albums", "album", "Albums"], ["artists", "mic", "Artists"], ["playlists", "playlist", "Playlists"], ["favorites", "heart", "Favorites"], ["files", "folder", "Play Files from This Phone"], ["import", "import", "Import a Spotify Playlist"], ["downloads", "download", "Downloads"], ["wrapped", "spark", "Your Wrapped"]]
        .map(([r, ic, label]) => `<a class="nav-row" href="#/${r}">${icon(ic)}${label}<span class="count">${icon("chev")}</span></a>`).join("")}`;
  },

  async albums() {
    let sort = store.get("albumSort", "alphabeticalByName"), offset = 0, done = false, busy = false;
    const sorts = { alphabeticalByName: "A–Z", newest: "Recently Added", alphabeticalByArtist: "Artist", frequent: "Most Played" };
    view.innerHTML = `${backLink()}<h1 class="title">Albums</h1>
      <div class="presets" style="margin-bottom:18px">${Object.entries(sorts).map(([k, v]) => `<button class="chip ${k === sort ? "on" : ""}" data-sort="${k}">${v}</button>`).join("")}</div>
      <div class="grid" id="grid"></div><div id="more-sentinel" style="height:40px"></div>`;
    const token = routeToken;
    const more = async () => {
      if (busy || done || token !== routeToken) return;
      busy = true;
      try {
        const page = await lib.albums(sort, 60, offset);
        if (token !== routeToken) return;
        offset += page.length; done = page.length < 60;
        $("#grid").insertAdjacentHTML("beforeend", page.map(albumCard).join(""));
      } catch (e) { $("#grid").innerHTML = errorBox(e); done = true; }
      busy = false;
    };
    $$("[data-sort]").forEach((b) => (b.onclick = () => { store.set("albumSort", b.dataset.sort); route(); }));
    new IntersectionObserver((entries) => entries[0].isIntersecting && more(), { rootMargin: "600px" }).observe($("#more-sentinel"));
    more();
  },

  async album(id) {
    view.innerHTML = loading();
    try {
      const a = await lib.album(id);
      const tracks = (a.song || []).map(toTrack).sort((x, y) => (x.disc || 1) - (y.disc || 1) || (x.track || 0) - (y.track || 0));
      screenTracks = tracks;
      const total = tracks.reduce((s, t) => s + t.duration, 0);
      const meta = [a.year, a.genre, `${tracks.length} songs`, total ? `${Math.round(total / 60)} min` : ""].filter(Boolean).join(" · ");
      const multi = new Set(tracks.map((t) => t.disc || 1)).size > 1;
      view.innerHTML = `<div class="album-wash">${backLink()}
        <div class="album-head"><img class="art" src="${cover(a.coverArt || a.id, 900)}" alt="">
          <h1>${esc(a.name)}</h1>
          ${a.artistId ? `<a class="by" href="#/artist/${esc(a.artistId)}">${esc(a.artist)}</a>` : `<span class="by">${esc(a.artist || "")}</span>`}
          <small>${esc(meta)}</small></div>
        ${playButtons()}
        <div id="album-list" style="margin-top:14px">${tracks.map((t, i) => `${multi && (i === 0 || tracks[i - 1].disc !== t.disc) ? `<div class="disc">Disc ${t.disc || 1}</div>` : ""}${trackRow(t, i, false, t.track || i + 1)}`).join("")}</div></div>`;
      view.querySelector(".album-wash").insertAdjacentHTML("beforeend",
        `<div class="pill-row" style="margin:22px 0 8px"><button class="pill danger-pill" id="del-album">${icon("x")}Delete Album…</button></div>`);
      $("#del-album").onclick = () => confirmDelete(tracks, `the album “${a.name}” (${tracks.length} song${tracks.length === 1 ? "" : "s"})`,
        () => setTimeout(() => history.back(), 600));
      if (window.getMusic) getMusic.fillAlbum(id, tracks, a);
      palette(a.coverArt || a.id).then((p) => {
        const w = $(".album-wash");
        if (!w) return;
        w.style.setProperty("--a-top", p.top); w.style.setProperty("--a-bottom", p.bottom); w.style.setProperty("--a-accent", p.accent);
        w.style.setProperty("--tint", p.accent);
      });
    } catch (e) { view.innerHTML = backLink() + errorBox(e); }
  },

  async artists() {
    view.innerHTML = `${backLink()}<h1 class="title">Artists</h1>
      <label class="field">${icon("search")}<input id="filter" placeholder="Filter artists" autocomplete="off"></label><div id="list" style="margin-top:12px">${loading()}</div>`;
    try {
      const all = await lib.artists();
      const render = (q) => {
        const list = all.filter((a) => !q || a.name.toLowerCase().includes(q.toLowerCase()));
        $("#list").innerHTML = list.map((a) => `<a class="row" href="#/artist/${esc(a.id)}"><img class="art round" loading="lazy" src="${cover(a.coverArt || a.id, 160)}" alt="">
          <div class="meta"><b>${esc(a.name)}</b><span>${a.albumCount || 0} album${a.albumCount === 1 ? "" : "s"}</span></div></a>`).join("") || `<div class="empty">No artists match.</div>`;
      };
      render("");
      $("#filter").oninput = (e) => render(e.target.value);
    } catch (e) { $("#list").innerHTML = errorBox(e); }
  },

  async artist(id) {
    view.innerHTML = loading();
    try {
      const a = await lib.artist(id);
      const albums = (a.album || []).sort((x, y) => (y.year || 0) - (x.year || 0));
      view.innerHTML = `${backLink()}<h1 class="title">${esc(a.name)}</h1>
        <div class="pill-row"><button class="pill primary" id="art-play">${icon("play")}Play</button><button class="pill" id="art-shuffle">${icon("shuffle")}Shuffle</button></div>
        <div class="grid" style="margin-top:22px">${albums.map((al) => albumCard({ ...al, artist: al.year || "" })).join("")}</div>`;
      const all = async (shuffle) => {
        const lists = await Promise.all(albums.map((al) => lib.album(al.id).then((x) => (x.song || []).map(toTrack)).catch(() => [])));
        player.play(lists.flat(), 0, shuffle);
      };
      $("#art-play").onclick = () => all(false);
      $("#art-shuffle").onclick = () => all(true);
    } catch (e) { view.innerHTML = backLink() + errorBox(e); }
  },

  async playlists() {
    view.innerHTML = `${backLink()}<h1 class="title">Playlists</h1>
      <div class="pill-row" style="margin-bottom:12px"><button class="pill primary" id="pl-create">${icon("plus")}New Playlist</button><a class="pill" href="#/import">${icon("import")}Import from Spotify</a></div><div id="list">${loading()}</div>`;
    $("#pl-create").onclick = () => newPlaylistSheet();
    try {
      const list = await lib.playlists();
      if (!$("#list")) return;   // left the screen while it loaded
      $("#list").innerHTML = list.map((p) => `<a class="row" href="#/playlist/${esc(p.id)}"><img class="art" loading="lazy" src="${cover(p.coverArt || p.id, 160)}" alt="">
        <div class="meta"><b>${esc(p.name)}</b><span>${p.songCount || 0} songs</span></div></a>`).join("")
        || `<div class="empty"><b>No playlists yet</b>Tap New Playlist, or tap ••• on any song and choose Add to Playlist.</div>`;
    } catch (e) { if ($("#list")) $("#list").innerHTML = errorBox(e); }
  },

  async playlist(id) {
    view.innerHTML = loading();
    try {
      const p = await lib.playlist(id);
      screenTracks = (p.entry || []).map(toTrack);
      view.innerHTML = `${backLink()}<div class="album-head"><img class="art" src="${cover(p.coverArt || p.id, 900)}" alt=""><h1>${esc(p.name)}</h1>
        <small>${screenTracks.length} songs</small></div>${playButtons()}
        <div style="margin-top:14px">${screenTracks.map((t, i) => trackRow(t, i)).join("")}</div>`;
    } catch (e) { view.innerHTML = backLink() + errorBox(e); }
  },

  async favorites() {
    view.innerHTML = `${backLink()}<h1 class="title">Favorites</h1><div id="fav">${loading()}</div>`;
    try {
      const r = await lib.starred();
      if (!$("#fav")) return;
      screenTracks = (r.song || []).map(toTrack);
      const albums = r.album || [];
      $("#fav").innerHTML = (albums.length ? `<div class="section-head"><h2 class="h2">Albums</h2></div><div class="shelf">${albums.map(albumCard).join("")}</div>` : "")
        + (screenTracks.length ? `<div class="section"><div class="section-head"><h2 class="h2">Songs</h2></div>${playButtons()}<div style="margin-top:12px">${screenTracks.map((t, i) => trackRow(t, i)).join("")}</div></div>` : "")
        || `<div class="empty"><b>No favorites yet</b>Tap the heart on the Now Playing screen to save songs here.</div>`;
    } catch (e) { $("#fav").innerHTML = errorBox(e); }
  },

  async search() {
    let mode = store.get("searchMode", "library"), kind = store.get("getKind", "song");
    view.innerHTML = `<h1 class="title">Search</h1>
      <div class="presets search-modes"><button class="chip" data-mode="library">Your Library</button><button class="chip" data-mode="get">${icon("download")}Download</button>
        <a class="dl-link" href="#/downloads" id="dl-badge-link"><span id="dl-badge"></span></a></div>
      <label class="field">${icon("search")}<input id="q" type="search" autocomplete="off" value="${esc(store.get("lastSearch", ""))}"></label>
      <div class="presets get-kinds"><button class="chip" data-kind="song">Songs</button><button class="chip" data-kind="album">Albums</button></div>
      <div id="results"></div>`;
    const input = $("#q");
    let timer, token = 0;
    const paint = () => {
      view.querySelectorAll("[data-mode]").forEach((b) => b.classList.toggle("on", b.dataset.mode === mode));
      view.querySelectorAll("[data-kind]").forEach((b) => b.classList.toggle("on", b.dataset.kind === kind));
      $(".get-kinds").hidden = mode !== "get";
      $("#dl-badge-link").hidden = mode !== "get";
      input.placeholder = mode === "get" ? (kind === "album" ? "Album or artist to download" : "Song to download (add the artist)") : "Songs, albums, artists";
    };
    view.querySelectorAll("[data-mode]").forEach((b) => b.onclick = () => { mode = b.dataset.mode; store.set("searchMode", mode); paint(); if (mode === "get") getMusic.badge(); run(); });
    view.querySelectorAll("[data-kind]").forEach((b) => b.onclick = () => { kind = b.dataset.kind; store.set("getKind", kind); paint(); run(); });
    paint();
    if (mode === "get") getMusic.badge();
    const run = async () => {
      const q = input.value.trim();
      store.set("lastSearch", q);
      const my = ++token;
      if (mode === "get") { $("#results").onclick = null; return getMusic.search(q, $("#results"), kind, () => my === token); }
      $("#results").onclick = null;
      if (!q) { $("#results").innerHTML = `<div class="empty"><b>Find anything</b>Search songs, albums and artists across your library.</div>`; return; }
      try {
        const r = await lib.search(q);
        if (my !== token) return;
        screenTracks = (r.song || []).map(toTrack);
        const artists = r.artist || [], albums = r.album || [];
        $("#results").innerHTML =
          (artists.length ? `<div class="section"><div class="section-head"><h2 class="h2">Artists</h2></div><div class="shelf">${artists.map((a) => `<a class="card" style="width:96px;text-align:center" href="#/artist/${esc(a.id)}">
            <img class="art round" style="width:96px;height:96px" loading="lazy" src="${cover(a.coverArt || a.id, 160)}" alt=""><b>${esc(a.name)}</b></a>`).join("")}</div></div>` : "")
          + (albums.length ? `<div class="section"><div class="section-head"><h2 class="h2">Albums</h2></div><div class="shelf">${albums.map(albumCard).join("")}</div></div>` : "")
          + (screenTracks.length ? `<div class="section"><div class="section-head"><h2 class="h2">Songs</h2></div>${screenTracks.map((t, i) => trackRow(t, i)).join("")}</div>` : "")
          || `<div class="empty"><b>No results</b>Nothing matches “${esc(q)}”.</div>`;
      } catch (e) { if (my === token) $("#results").innerHTML = errorBox(e); }
    };
    input.oninput = () => { clearTimeout(timer); timer = setTimeout(run, mode === "get" ? 600 : 300); };
    input.onkeydown = (e) => { if (e.key === "Enter") { clearTimeout(timer); run(); input.blur(); } };
    run();
    if (!input.value) input.focus();
  },

  async files() {
    view.innerHTML = `${backLink()}<h1 class="title">Files on This Phone</h1>
      <div class="pill-row"><button class="pill primary" id="pick">${icon("folder")}Choose Songs</button></div>
      <p class="note">Pick songs from the Files app to play them here with the EQ. The web version can't keep them between visits, so you'll pick them again next time.</p>
      <div id="picked" style="margin-top:12px"></div>`;
    const render = () => {
      screenTracks = localTracks;
      $("#picked").innerHTML = localTracks.length ? playButtons() + `<div style="margin-top:12px">${localTracks.map((t, i) => trackRow(t, i)).join("")}</div>` : "";
    };
    $("#pick").onclick = () => $("#file-pick").click();
    $("#file-pick").onchange = (e) => {
      for (const f of e.target.files) {
        const name = f.name.replace(/\.[^.]+$/, "");
        const [artist, title] = name.includes(" - ") ? name.split(" - ", 2) : ["On this phone", name];
        localTracks.push({ id: "local-" + Math.random().toString(36).slice(2), title: title.trim(), artist: artist.trim(), album: "On this phone", duration: 0, local: URL.createObjectURL(f) });
      }
      e.target.value = "";
      render();
    };
    render();
  },

  async settings() {
    view.innerHTML = `<h1 class="title">Settings</h1>
      <div class="form">
        <label><span>Navidrome username</span><input id="s-user" autocomplete="username" value="${esc(cfg.user)}"></label>
        <label><span>Password</span><input id="s-pass" type="password" autocomplete="current-password" value="${esc(cfg.pass)}"></label>
      </div>
      <div class="pill-row" style="margin-top:14px"><button class="pill primary" id="s-save">Save & Test</button></div>
      <p class="note" id="s-result"></p>
      <div class="form" style="margin-top:26px">
        <label><span>Streaming quality</span><select id="s-quality">
          <option value="original">Original</option><option value="high">High (320 kbps)</option><option value="saver">Data Saver (160 kbps)</option></select></label>
      </div>
      <p class="note">Original plays your files exactly as they are. Lower quality uses less cellular data.</p>
      <div class="form" style="margin-top:26px">
        <label style="display:flex;align-items:center;justify-content:space-between" id="s-eq"><span style="font-size:17px;color:#fff">Equalizer</span><span>${eq.enabled ? esc(eq.preset) : "Off"} ›</span></label>
      </div>
      <p class="note">Add Platter to your Home Screen (Share › Add to Home Screen) so it opens full screen like an app.</p>
      <p class="note">Platter web ${esc(loadedVersion || "")}. To update, drop a new zip into the updates folder on your NAS.</p>`;
    $("#s-quality").value = quality;
    $("#s-quality").onchange = (e) => { quality = e.target.value; store.set("quality", quality); };
    $("#s-eq").onclick = openEQ;
    $("#s-save").onclick = async () => {
      cfg = { user: $("#s-user").value.trim(), pass: $("#s-pass").value };
      store.set("cfg", cfg);
      const res = $("#s-result");
      res.className = "note"; res.textContent = "Testing…";
      try { await api("ping"); res.className = "note ok"; res.textContent = "Connected. Your music is ready."; }
      catch (e) { res.className = "note bad"; res.textContent = e.message; }
    };
  },

  async welcome() {
    $("#dock").hidden = true;
    view.innerHTML = `<div class="welcome">
      <span class="mark"><img src="icons/icon-192.png" alt=""><b>Platter</b></span>
      <h1>All your music.<br>Your sound.</h1>
      <p>Sign in with your Navidrome account to stream everything on your NAS through a real 10-band equalizer.</p>
      <div class="form">
        <label><span>Username</span><input id="w-user" autocomplete="username" autocapitalize="off"></label>
        <label><span>Password</span><input id="w-pass" type="password" autocomplete="current-password"></label>
      </div>
      <button class="pill primary" id="w-go" style="flex:none">Sign In</button>
      <p class="note bad" id="w-err" style="margin:0"></p></div>`;
    $("#w-go").onclick = async () => {
      cfg = { user: $("#w-user").value.trim(), pass: $("#w-pass").value };
      try {
        await api("ping");
        store.set("cfg", cfg);
        $("#dock").hidden = false;
        location.hash = "#/";
        route();
      } catch (e) { $("#w-err").textContent = e.message; }
    };
  },
};
const localTracks = [];

/** The blurred cover behind Now Playing: shrunk to a few pixels once per song and scaled up,
    which looks just as soft as a big blur but costs almost nothing to draw. */
function softBackdrop(coverArt) {
  const img = $("#np .backdrop img");
  if (!coverArt) { img.removeAttribute("src"); return; }
  const src = new Image();
  src.crossOrigin = "anonymous";
  src.onload = () => {
    try {
      // blur it once here (tiny, then softened at a medium size), so the drifting background only moves a finished
      // picture each frame instead of re-blurring it: a lot lighter on phones
      const tiny = document.createElement("canvas");
      tiny.width = tiny.height = 16;
      tiny.getContext("2d").drawImage(src, 0, 0, 16, 16);
      const c = document.createElement("canvas");
      c.width = c.height = 128;
      const g = c.getContext("2d");
      g.imageSmoothingQuality = "high";
      if ("filter" in g) g.filter = "blur(7px) saturate(1.3)";
      g.drawImage(tiny, -16, -16, 160, 160);
      img.src = c.toDataURL("image/jpeg", 0.9);
    } catch { img.src = src.src; }
  };
  src.src = cover(coverArt, 160);
}

function route() {
  routeToken++;
  screenTracks = [];
  if (window.importer) importer.stopPolling();
  if (!cfg.user || !cfg.pass) return screens.welcome();
  $("#dock").hidden = false;
  const [name, arg] = location.hash.replace(/^#\/?/, "").split("/");
  const screen = screens[name || "home"] && name !== "welcome" ? name || "home" : "home";
  const tab = { wrapped: "library", albums: "library", artists: "library", playlists: "library", favorites: "library", files: "library", album: "library", artist: "library", playlist: "library", import: "library", downloads: "library", getalbum: "search", mix: "home" }[screen] || screen;
  $$("#tabs a").forEach((a) => a.classList.toggle("on", a.dataset.tab === tab));
  window.scrollTo(0, 0);
  screens[screen](arg && decodeURIComponent(arg));
}

/* ============================================================
   Wiring
   ============================================================ */
$("#mini").onclick = (e) => {
  if (e.target.closest("#mini-play")) return player.toggle();
  if (e.target.closest("#mini-next")) return player.skip();
  openNP();
};
$("#np-close").onclick = closeNP;
$("#np-play").onclick = () => player.toggle();
$("#np-next").onclick = () => player.skip();
$("#np-prev").onclick = () => player.prev();
$("#np-shuffle").onclick = () => player.toggleShuffle();
$("#np-repeat").onclick = () => player.cycleRepeat();
$("#np-heart").onclick = () => player.star(!player.current?.starred);
$("#np-eq").onclick = openEQ;
$("#np-screw").onclick = openScrew;
function openScrew() {
  const m = $("#menu");
  const render = () => {
    m.innerHTML = `<div class="panel screw-panel">
      <h3>Chopped &amp; Screwed</h3><p class="sp-sub">Slow it down like a record, and let it cut back on the beat.</p>
      <small>SPEED</small><div class="sp-grid">${Object.entries(SPEEDS).map(([k, [n, r, d]]) =>
        `<button data-speed="${k}" class="${screw.speed === k ? "on" : ""}"><b>${n}</b><span>${k === "off" ? "Normal" : `${Math.round(r * 100)}% · ${d}`}</span></button>`).join("")}</div>
      <small>CHOPS</small><div class="sp-row">${[["off", "None"], ["light", "Every few bars"], ["heavy", "Every bar"], ["live", "You tap them"]].map(([k, d]) =>
        `<button data-chops="${k}" class="${screw.chops === k ? "on" : ""}"><b>${k[0].toUpperCase() + k.slice(1)}</b><span>${d}</span></button>`).join("")}</div>
      ${screw.chops === "live" ? `<p class="sp-live">The cover turns into a record: drag around it to scratch, hold it to stop, spin it hard to skip. Pads show up under the song: tap one and it cuts back right away, in time. Hold <b>Repeat</b> to loop a beat.${matchMedia("(pointer: fine)").matches ? " Keys 1–5 work too." : ""}</p>` : ""}
      ${screw.chops !== "off" ? `<p class="sp-status" id="sp-status"></p>` : ""}
      <p class="sp-note">Chops follow the song's beat: repeats, run-backs, stutters and back-it-ups. They start a few seconds into each song, once Platter has found the rhythm.</p>
      <button class="sp-done">Done</button></div>`;
  };
  let timer = 0;
  const MOVE_NAMES = { repeatBeat: "Repeat", runBack: "Run it back", stutter: "Stutter", doubleUp: "Double up", backItUp: "Back it up" };
  const status = () => {
    const el = $("#sp-status");
    if (m.hidden) return clearInterval(timer);
    if (!el) return;
    const st = screw.stats, locked = st && st.confidence > 0.15 && st.bpm > 0;
    el.classList.toggle("locked", !!locked);
    el.textContent = locked ? `Locked on beat · ${Math.round(st.bpm)} BPM${st.last ? ` · last: ${MOVE_NAMES[st.last] || st.last}` : ""}` : "Listening for the beat…";
  };
  render();
  m.hidden = false;
  status();
  timer = setInterval(status, 500);
  m.onclick = (e) => {
    if (e.target === m || e.target.closest(".sp-done")) { m.hidden = true; clearInterval(timer); return; }
    const b = e.target.closest("[data-speed], [data-chops]");
    if (!b) return;
    audio.ensure();
    screw.set(b.dataset.speed, b.dataset.chops);
    render();
    status();
  };
}
// tap the artist under the song title: go to their page
$("#np-artist").onclick = async () => {
  const t = player.current;
  if (!t) return;
  let id = t.artistId;
  if (!id && t.artist) {          // a song from your Files without an artist link: look the name up
    try { const r = await lib.searchArtist(t.artist); id = r && r.id; } catch { /* below */ }
  }
  if (!id) return toast(`Couldn't find ${t.artist} in your library`);
  closeNP();
  location.hash = `#/artist/${id}`;
};
$("#np-queue").onclick = () => { $("#queue").hidden = false; renderQueue(); };
$("#np-more").onclick = () => player.current && showMenu(player.current.title, [player.current]);

const seek = $("#np-seek");
seek.oninput = () => {
  scrubbing = true;
  const d = player.duration(), s = (seek.value / 1000) * d;
  seek.style.setProperty("--p", `${seek.value / 10}%`);
  $("#np-cur").textContent = fmt(s);
  $("#np-left").textContent = "-" + fmt(d - s);
};
seek.onchange = () => { player.seek((seek.value / 1000) * player.duration()); scrubbing = false; };

// mini player: swipe left/right to skip, swipe up to open Now Playing
(() => {
  const mini = $("#mini");
  let sx = 0, sy = 0, dx = 0, on = false, moved = false;
  mini.addEventListener("touchstart", (e) => { sx = e.touches[0].clientX; sy = e.touches[0].clientY; dx = 0; on = true; moved = false; }, { passive: true });
  mini.addEventListener("touchmove", (e) => {
    if (!on) return;
    dx = e.touches[0].clientX - sx;
    const dy = e.touches[0].clientY - sy;
    if (Math.abs(dx) > 10 && Math.abs(dx) > Math.abs(dy)) { moved = true; mini.classList.add("swiping"); mini.style.transform = `translateX(${dx * 0.35}px)`; }
    if (dy < -40 && Math.abs(dy) > Math.abs(dx)) { on = false; moved = true; openNP(); }
  }, { passive: true });
  mini.addEventListener("touchend", () => {
    if (!on) return;
    on = false;
    mini.classList.remove("swiping");
    mini.style.transform = "";
    if (dx < -60) player.skip(); else if (dx > 60) player.prev();
    if (moved) mini.dataset.swiped = "1";
  });
  mini.addEventListener("click", (e) => { if (mini.dataset.swiped) { delete mini.dataset.swiped; e.stopImmediatePropagation(); } }, true);
})();

// swipe down to close Now Playing, swipe sideways on the art to skip
(() => {
  const np = $("#np");
  let sx = 0, sy = 0, dragging = false, onArt = false;
  np.addEventListener("touchstart", (e) => {
    if (e.target.closest("input, .controls, .np-bottom, .vinyl, .np-pads")) return;
    sx = e.touches[0].clientX; sy = e.touches[0].clientY; dragging = true; onArt = !!e.target.closest(".np-stage") && !e.target.closest(".viz-ui");
  }, { passive: true });
  np.addEventListener("touchmove", (e) => {
    if (!dragging) return;
    const dy = e.touches[0].clientY - sy;
    if (dy > 0 && Math.abs(dy) > Math.abs(e.touches[0].clientX - sx)) { np.style.transition = "none"; np.style.transform = `translateY(${dy}px)`; }
  }, { passive: true });
  np.addEventListener("touchend", (e) => {
    if (!dragging) return;
    dragging = false;
    const dx = e.changedTouches[0].clientX - sx, dy = e.changedTouches[0].clientY - sy;
    np.style.transition = "";
    if (dy > 120 && Math.abs(dy) > Math.abs(dx)) closeNP();
    else np.style.transform = "";
    if (onArt && Math.abs(dx) > 80 && Math.abs(dx) > Math.abs(dy)) dx < 0 ? player.skip() : player.prev();
  });
})();

document.addEventListener("keydown", (e) => {
  if (e.target.matches("input, select, textarea")) return;
  if (e.code === "Space") { e.preventDefault(); player.toggle(); }
  if (e.key === "Escape") { if (!$("#eq").hidden) $("#eq").hidden = true; else if (!$("#queue").hidden) $("#queue").hidden = true; else if (!$("#np").hidden) closeNP(); }
});

/* ============================================================
   Updates: notice when a new version was dropped into the updates folder
   ============================================================ */
let loadedVersion = null;
async function checkForUpdate() {
  try {
    const r = await fetch("version.txt", { cache: "no-store" });
    if (!r.ok) return;
    const v = (await r.text()).trim();
    if (!loadedVersion) { loadedVersion = v; return; }
    if (v === loadedVersion) return;
    if (!player.current) { location.reload(); return; }    // nothing loaded: just switch
    const t = $("#toast");
    t.textContent = `Platter ${v} is installed. Tap here to refresh.`;
    t.hidden = false;
    clearTimeout(toast.timer);
    t.onclick = () => location.reload();
  } catch { /* offline, try later */ }
}
checkForUpdate();
setInterval(checkForUpdate, 120000);
document.addEventListener("visibilitychange", () => { if (!document.hidden) checkForUpdate(); });

window.addEventListener("hashchange", () => {
  const calm = matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (document.startViewTransition && !calm && !document.hidden) { const vt = document.startViewTransition(route); vt.ready.catch(() => {}); vt.finished.catch(() => {}); vt.updateCallbackDone.catch(() => {}); }
  else route();
});
if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", route); else route();   // after the add-on scripts load
