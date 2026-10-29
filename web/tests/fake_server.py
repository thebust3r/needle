"""A pretend Navidrome: serves the web app and fake /rest answers with generated audio and covers."""
import io, json, math, os, random, struct, sys, wave, colorsys
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from PIL import Image, ImageDraw

SITE = sys.argv[1]
random.seed(4)
ARTISTS = ["Neon Harbor", "Velvet Static", "Paper Moons", "Low Orbit", "The Quiet Fires"]
GENRES = ["Synthwave", "Indie", "Dream Pop", "Synthwave", "Folk"]
WORDS = ["Midnight", "Glass", "Summer", "Echo", "Drive", "Gold", "Hollow", "Satellite", "Rain", "Ember", "Signal", "Coast"]
albums, songs = [], {}
for ai in range(14):
    art = ARTISTS[ai % len(ARTISTS)]
    aid = f"al{ai}"
    name = f"{random.choice(WORDS)} {random.choice(WORDS)}"
    tracks = []
    for t in range(1, random.randint(7, 11)):
        sid = f"s{ai}_{t}"
        s = {"id": sid, "title": f"{random.choice(WORDS)} {random.choice(['Lights','Waves','Heart','Lines','Days'])}", "album": name, "artist": art,
             "albumId": aid, "artistId": f"ar{ai % 5}", "track": t, "discNumber": 1, "coverArt": aid, "suffix": "wav", "duration": 30, "year": 2015 + ai % 9,
             "genre": GENRES[ai % 5], "playCount": (ai * 7 + t * 3) % 15}
        songs[sid] = s; tracks.append(s)
    albums.append({"id": aid, "name": name, "artist": art, "artistId": f"ar{ai % 5}", "coverArt": aid, "songCount": len(tracks), "year": 2015 + ai % 9, "genre": GENRES[ai % 5], "song": tracks})

def cover_png(aid, size):
    random.seed(aid)
    h = random.random()
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        r, g, b = colorsys.hsv_to_rgb((h + y / size * 0.15) % 1, 0.65, 0.35 + 0.5 * (1 - y / size))
        d.line([(0, y), (size, y)], fill=(int(r * 255), int(g * 255), int(b * 255)))
    r, g, b = colorsys.hsv_to_rgb((h + 0.5) % 1, 0.8, 0.95)
    d.ellipse([size * .25, size * .25, size * .75, size * .75], fill=(int(r * 255), int(g * 255), int(b * 255)))
    buf = io.BytesIO(); img.save(buf, "JPEG", quality=85); return buf.getvalue()

def tone_wav(seed):
    random.seed(seed)
    base = random.choice([110, 130.8, 146.8, 164.8])
    rate, secs = 22050, 30
    buf = io.BytesIO(); w = wave.open(buf, "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
    frames = bytearray()
    for i in range(rate * secs):
        t = i / rate
        beat = (t * 2) % 1
        v = 0.25 * math.sin(2 * math.pi * base * t) + 0.12 * math.sin(2 * math.pi * base * 3 * t) + 0.08 * math.sin(2 * math.pi * base * 6.01 * t)
        v += 0.35 * math.sin(2 * math.pi * 55 * t) * math.exp(-beat * 9)       # kick-ish
        v += (random.random() - 0.5) * 0.08 * math.exp(-((t * 4) % 1) * 20)    # hat-ish
        frames += struct.pack("<h", int(max(-1, min(1, v)) * 30000))
    w.writeframes(bytes(frames)); w.close(); return buf.getvalue()

WAVS = {}
CREATED = []
HISTORY = []          # stand-in for the helper's shared listening history when no real helper is running
HELPER = os.environ.get("HELPER_URL")          # forward /helper/ to a running helper (import tests)
REST_FWD = os.environ.get("REST_FORWARD")       # playlists live in the helper's fake Navidrome
from urllib.request import Request as _Req, urlopen as _open
from urllib.error import HTTPError as _HE

class H(SimpleHTTPRequestHandler):
    def forward(self, base, method):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        req = _Req(base + self.path, data=body, method=method, headers={"Content-Type": self.headers.get("Content-Type", "application/json")})
        try:
            with _open(req, timeout=30) as r: code, data, ct = r.status, r.read(), r.headers.get("Content-Type", "")
        except _HE as e: code, data, ct = e.code, e.read(), e.headers.get("Content-Type", "")
        except Exception: code, data, ct = 502, b"<html>Bad Gateway</html>", "text/html"
        self.send_response(code); self.send_header("Content-Type", ct); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        if self.path.startswith("/helper/history") and not HELPER:
            n = int(self.headers.get("Content-Length") or 0)
            plays = json.loads(self.rfile.read(n) or b"{}").get("plays", [])
            keys = {(p.get("device"), p.get("at")) for p in HISTORY}
            HISTORY.extend(p for p in plays if (p.get("device"), p.get("at")) not in keys)
            return self.json({"ok": True, "changed": len(plays)})
        if self.path.startswith("/helper/"):
            if not HELPER: return self.forward("http://127.0.0.1:1", "POST")
            return self.forward(HELPER, "POST")
        self.send_error(404)
    def do_DELETE(self):
        if self.path.startswith("/helper/") and HELPER: return self.forward(HELPER, "DELETE")
        self.send_error(404)
    def __init__(self, *a, **k): super().__init__(*a, directory=SITE, **k)
    def log_message(self, *a): pass
    def ok(self, payload):
        body = json.dumps({"subsonic-response": {"status": "ok", "version": "1.16.1", **payload}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        u = urlparse(self.path); q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path.startswith("/helper/history") and not HELPER:
            return self.json({"plays": HISTORY})
        if u.path == "/_history":
            return self.json(HISTORY)
        if u.path.startswith("/helper/"):
            return self.forward(HELPER or "http://127.0.0.1:1", "GET")
        if u.path == "/_created":
            b = json.dumps(CREATED).encode(); self.send_response(200); self.end_headers(); return self.wfile.write(b)
        if REST_FWD and u.path in ("/rest/getPlaylist", "/rest/getPlaylists"):
            return self.forward(REST_FWD, "GET")
        if u.path.startswith("/lrclib/api/"):
            title = q.get("track_name", "")
            if "Drive" in title or "Echo" in title:
                lrc = "[offset:+0]\n" + "\n".join(f"[00:{i*3:02d}.{(i*37)%100:02d}]Line {i+1} of {title}" for i in range(10)) + "\n[00:31.00][00:33.50]Repeated tail"
                body = json.dumps({"trackName": title, "duration": 30, "instrumental": False, "plainLyrics": "plain", "syncedLyrics": lrc})
                if u.path.endswith("/search"): body = "[" + body + "]"
                self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); return self.wfile.write(body.encode())
            if u.path.endswith("/search"):
                self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); return self.wfile.write(b"[]")
            self.send_response(404); self.end_headers(); return
        if not u.path.startswith("/rest/"): return super().do_GET()
        ep = u.path[6:]
        strip = lambda a: {k: v for k, v in a.items() if k != "song"}
        if ep == "ping": return self.ok({})
        if ep == "getLyricsBySongId":
            if q["id"].startswith("s1_"):   # album al1 has lyrics in its files
                return self.ok({"lyricsList": {"structuredLyrics": [{"synced": True, "lang": "eng", "offset": 0,
                    "line": [{"start": i * 2500, "value": f"File lyric {i+1}"} for i in range(12)]}]}})
            return self.ok({"lyricsList": {"structuredLyrics": []}})
        if ep == "getAlbumList2":
            lst = albums[:]; random.shuffle(lst) if q.get("type") in ("random", "recent", "frequent") else None
            off = int(q.get("offset", 0)); size = int(q.get("size", 20))
            return self.ok({"albumList2": {"album": [strip(a) for a in lst[off:off + size]]}})
        if ep == "getAlbum": return self.ok({"album": next(a for a in albums if a["id"] == q["id"])})
        if ep == "getArtists": return self.ok({"artists": {"index": [{"name": "A", "artist": [{"id": f"ar{i}", "name": n, "albumCount": 3, "coverArt": f"al{i}"} for i, n in enumerate(ARTISTS)]}]}})
        if ep == "getArtist":
            i = int(q["id"][2:]); return self.ok({"artist": {"id": q["id"], "name": ARTISTS[i], "album": [strip(a) for a in albums if a["artistId"] == q["id"]]}})
        if ep == "search3":
            ql = q.get("query", "").lower()
            return self.ok({"searchResult3": {"album": [strip(a) for a in albums if ql in a["name"].lower()], "song": [s for s in songs.values() if ql in s["title"].lower()][:20]}})
        if ep == "getRandomSongs":
            allv = list(songs.values()); return self.ok({"randomSongs": {"song": random.sample(allv, min(len(allv), int(q.get("size", 20))))}})
        if ep == "getSongsByGenre":
            return self.ok({"songsByGenre": {"song": [x for x in songs.values() if x["genre"] == q.get("genre")][:int(q.get("count", 10))]}})
        if ep == "getArtistInfo2":
            i = int(q["id"][2:])
            return self.ok({"artistInfo2": {"biography": f'{ARTISTS[i]} is a band from somewhere &amp; elsewhere. <a href="https://last.fm">Read more on Last.fm</a>',
                "largeImageUrl": "", "similarArtist": [{"id": f"ar{(i + 1) % 5}", "name": ARTISTS[(i + 1) % 5], "coverArt": f"al{(i + 1) % 5}"}]}})
        if ep == "createPlaylist":
            CREATED.append({k: v for k, v in parse_qs(u.query).items() if k in ("name", "songId")}); return self.ok({"playlist": {"id": "pl9", "name": q.get("name")}})
        if ep == "getStarred2": return self.ok({"starred2": {"song": [songs["s2_1"], songs["s2_2"]], "album": []}})
        if ep in ("getPlaylists", "star", "unstar", "scrobble"): return self.ok({"playlists": {"playlist": []}} if ep == "getPlaylists" else {})
        if ep == "getCoverArt":
            body = cover_png(q["id"], min(int(q.get("size", 300)), 600))
            self.send_response(200); self.send_header("Content-Type", "image/jpeg"); self.send_header("Content-Length", str(len(body))); self.send_header("Cache-Control", "max-age=3600"); self.end_headers(); return self.wfile.write(body)
        if ep == "stream":
            key = q["id"][:4]
            if key not in WAVS: WAVS[key] = tone_wav(key)
            body = WAVS[key]
            rng = self.headers.get("Range")
            if rng:
                a, b = rng.replace("bytes=", "").split("-"); a = int(a); b = int(b) if b else len(body) - 1
                part = body[a:b + 1]
                self.send_response(206); self.send_header("Content-Range", f"bytes {a}-{b}/{len(body)}")
            else:
                part = body; self.send_response(200)
            self.send_header("Content-Type", "audio/wav"); self.send_header("Accept-Ranges", "bytes"); self.send_header("Content-Length", str(len(part))); self.end_headers()
            try: self.wfile.write(part)
            except BrokenPipeError: pass
            return
        self.send_error(404)
ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("PORT", 8796))), H).serve_forever()
