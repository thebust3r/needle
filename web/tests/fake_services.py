"""Pretend Spotify embed pages, Navidrome, slskd, Lidarr and MusicBrainz for testing the helper.
Usage: python3 fake_services.py PORT MUSIC_DIR DOWNLOADS_DIR"""
import json, os, re, sys, threading, time, html
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import hashlib

PORT, MUSIC, DOWNLOADS = int(sys.argv[1]), sys.argv[2], sys.argv[3]
USER, PASS = "mason", "secret"
LOCK = threading.Lock()

# ---------------- Navidrome library
songs = {}
def add_song(title, artist, duration=200, path=None, album="Album"):
    sid = f"s{len(songs) + 1}"
    songs[sid] = {"id": sid, "title": title, "artist": artist, "album": album, "duration": duration, "path": path or f"{artist}/{album}/{title}.mp3"}
    return sid

for t, a, d in [
    ("Stressed Out", "Twenty One Pilots", 202), ("Heathens", "Twenty One Pilots", 195),
    ("Hey Jude", "The Beatles", 431), ("Señorita", "Shawn Mendes & Camila Cabello", 190),
    ("Sicko Mode", "Travis Scott", 312), ("Mask Off", "Future", 204), ("Ride", "Twenty One Pilots", 214),
    ("Ultralight Beam", "Kanye West", 320), ("Tear da Club Up", "Three 6 Mafia", 250),
    ("Smells Like Teen Spirit", "Nirvana", 301), ("Lovely Day", "Bill Withers", 254),
]:
    add_song(t, a, d)
playlists = {}
seen_files = set()

def scan():
    for root, _, files in os.walk(MUSIC):
        for f in files:
            p = os.path.join(root, f)
            if p in seen_files: continue
            seen_files.add(p)
            rel = os.path.relpath(p, MUSIC)
            artist = os.path.basename(root)
            name = re.sub(r"^\d+\s*[-.]?\s*", "", os.path.splitext(f)[0])
            if " - " in name: artist, name = name.split(" - ", 1)
            add_song(name, artist, 0, rel)

def auth_ok(q):
    return q.get("u") == USER and q.get("t") == hashlib.md5((PASS + q.get("s", "")).encode()).hexdigest()

# ---------------- Spotify embed pages
def sp_item(title, artists, sec):
    return {"uri": "spotify:track:" + hashlib.md5(title.encode()).hexdigest()[:22], "title": title, "subtitle": ", ".join(artists), "duration": sec * 1000, "isExplicit": False}

SPOTIFY = {
    "testmix0000000000000001": ("Road Trip Mix", [
        sp_item("Stressed Out", ["Twenty One Pilots"], 202),
        sp_item("Hey Jude - Remastered 2015", ["The Beatles"], 431),
        sp_item("Señorita", ["Shawn Mendes", "Camila Cabello"], 191),
        sp_item("SICKO MODE (feat. Drake)", ["Travis Scott", "Drake"], 312),
        sp_item("Mask Off", ["Future"], 204),
        sp_item("Ride - Live", ["Twenty One Pilots"], 260),          # only the studio version is in the library
        sp_item("Ultralight Beam", ["Kanye West"], 320),
        sp_item("Midnight City", ["M83"], 244),                        # missing: Soulseek has it
        sp_item("Weird Fishes", ["Radiohead"], 318),                   # missing: first user fails, second works
        sp_item("Obscure Song", ["Nobody Known"], 180),                # missing: only remixes out there
        sp_item("Tear da Club Up", ["Three 6 Mafia"], 250),
        sp_item("Lovely Day", ["Bill Withers"], 254),
    ]),
    "big00000000000000000001": ("Huge", [sp_item(f"Song {i}", ["Band"], 200) for i in range(100)]),
    "albumrequest00000000001": ("Album Test", [sp_item("Stressed Out", ["Twenty One Pilots"], 202), sp_item("Holocene", ["Bon Iver"], 337)]),
}

def embed_page(sid):
    name, items = SPOTIFY[sid]
    data = {"props": {"pageProps": {"state": {"data": {"entity": {"type": "playlist", "name": name, "title": name, "subtitle": "Someone",
            "trackList": items}}, "settings": {}}}}, "page": "/embed/playlist/[id]"}
    return ("<!DOCTYPE html><html><head><title>Spotify Embed</title></head><body><div id=\"__next\"></div>"
            f'<script id="__NEXT_DATA__" type="application/json">{json.dumps(data)}</script></body></html>')

# ---------------- slskd
SLSK_FILES = {
    "m83 midnight city": [
        {"username": "slowpoke", "hasFreeUploadSlot": False, "uploadSpeed": 50000, "queueLength": 40,
         "files": [{"filename": "@@a\\Music\\M83\\Hurry Up\\03 - Midnight City.mp3", "size": 3000, "bitRate": 192, "length": 244}]},
        {"username": "goodguy", "hasFreeUploadSlot": True, "uploadSpeed": 4000000, "queueLength": 0,
         "files": [{"filename": "@@b\\Music\\M83\\Hurry Up We're Dreaming\\04 - Midnight City.flac", "size": 5000, "length": 243},
                   {"filename": "@@b\\Music\\M83\\Remixes\\Midnight City (Eric Prydz Remix).flac", "size": 6000, "length": 400},
                   {"filename": "@@b\\Music\\M83\\Hurry Up We're Dreaming\\cover.jpg", "size": 10}]}],
    "radiohead weird fishes": [
        {"username": "flaky", "hasFreeUploadSlot": True, "uploadSpeed": 9000000, "queueLength": 0,
         "files": [{"filename": "@@c\\Radiohead\\In Rainbows\\04 Weird Fishes.flac", "size": 7000, "length": 318}]},
        {"username": "steady", "hasFreeUploadSlot": True, "uploadSpeed": 1000000, "queueLength": 0,
         "files": [{"filename": "@@d\\mp3\\Radiohead - In Rainbows\\04 - Weird Fishes_Arpeggi.mp3", "size": 4000, "bitRate": 320, "length": 318}]}],
    "nobody known obscure song": [
        {"username": "remixer", "hasFreeUploadSlot": True, "uploadSpeed": 1000000, "queueLength": 0,
         "files": [{"filename": "@@e\\Nobody Known\\Obscure Song (Club Remix).mp3", "size": 100, "length": 300}]}],
}
searches, transfers = {}, {}
slsk_log = []

def transfer_state(user, f):
    f["polls"] = f.get("polls", 0) + 1
    if user == "flaky" and f["polls"] > 1:
        f["state"] = "Completed, Errored"
    elif f["polls"] > 2:
        if f["state"] != "Completed, Succeeded":
            path = f["filename"].replace("\\", "/").split("/")
            d = os.path.join(DOWNLOADS, path[-2]); os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, path[-1]), "wb") as out: out.write(b"x" * f["size"])
        f["state"] = "Completed, Succeeded"; f["percentComplete"] = 100
    else:
        f["state"] = "InProgress"; f["percentComplete"] = 40

# ---------------- Lidarr + MusicBrainz
lidarr_albums = []
lidarr_log = []
MB = {"holocene": {"recordings": [{"id": "r1", "score": 100, "title": "Holocene", "releases": [
        {"id": "x1", "title": "Holocene", "status": "Official", "date": "2012-01-01", "release-group": {"id": "rg-single", "primary-type": "Single"}},
        {"id": "x2", "title": "Bon Iver, Bon Iver", "status": "Official", "date": "2011-06-17", "release-group": {"id": "rg-album", "primary-type": "Album", "title": "Bon Iver, Bon Iver"}},
        {"id": "x3", "title": "Live", "status": "Official", "date": "2010-01-01", "release-group": {"id": "rg-live", "primary-type": "Album", "secondary-types": ["Live"]}}]}]}}

def lidarr_download(album):
    time.sleep(1.0)
    with LOCK:
        add_song("Holocene", "Bon Iver", 337, "Bon Iver/Bon Iver, Bon Iver/03 Holocene.flac", "Bon Iver, Bon Iver")
        add_song("Perth", "Bon Iver", 262, "Bon Iver/Bon Iver, Bon Iver/01 Perth.flac", "Bon Iver, Bon Iver")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def j(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def sub(self, payload, ok=True):
        self.j({"subsonic-response": {"status": "ok" if ok else "failed", "version": "1.16.1", **payload}})
    def read(self):
        n = int(self.headers.get("Content-Length") or 0); return self.rfile.read(n) if n else b""

    def handle_req(self, method):
        u = urlparse(self.path); q = {k: v for k, v in parse_qs(u.query).items()}
        body = self.read() if method in ("POST", "PUT") else b""
        p = u.path
        # Spotify
        m = re.match(r"^/embed/(playlist|album)/(\w+)$", p)
        if m:
            if m.group(2) not in SPOTIFY: self.send_response(404); self.end_headers(); return
            b = embed_page(m.group(2)).encode()
            self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(b); return
        # Navidrome
        if p.startswith("/rest/"):
            if method == "POST" and body: q.update(parse_qs(body.decode()))
            one = {k: v[0] for k, v in q.items()}
            if not auth_ok(one): return self.sub({"error": {"code": 40, "message": "Wrong username or password"}}, ok=False)
            ep = p[6:].replace(".view", "")
            with LOCK:
                if ep == "ping": return self.sub({})
                if ep == "startScan": scan(); return self.sub({"scanStatus": {"scanning": True}})
                if ep == "search3":
                    words = [w for w in re.split(r"\W+", one.get("query", "").lower()) if w]
                    hits = []
                    for s in songs.values():
                        hay = re.sub(r"[^a-z0-9 ]", " ", (s["title"] + " " + s["artist"] + " " + s["album"]).lower().replace("ñ", "n"))
                        if all(any(h.startswith(w) for h in hay.split()) for w in words): hits.append(s)
                    return self.sub({"searchResult3": {"song": hits[:int(one.get("songCount", 20))]}})
                if ep == "createPlaylist":
                    ids = q.get("songId", [])
                    if "playlistId" in one:
                        playlists[one["playlistId"]]["songs"] = ids
                        return self.sub({})
                    pid = f"pl{len(playlists) + 1}"
                    playlists[pid] = {"id": pid, "name": one["name"], "songs": ids, "created": time.strftime("%Y-%m-%dT%H:%M:%S")}
                    return self.sub({"playlist": {"id": pid, "name": one["name"], "songCount": len(ids)}})
                if ep == "getPlaylists": return self.sub({"playlists": {"playlist": [{"id": k, "name": v["name"]} for k, v in playlists.items()]}})
                if ep == "getPlaylist":
                    pl = playlists[one["id"]]; return self.sub({"playlist": {"id": pl["id"], "name": pl["name"], "entry": [songs[s] for s in pl["songs"]]}})
            return self.sub({"error": {"message": "unknown"}}, ok=False)
        # slskd
        if p.startswith("/slskd/api/v0/"):
            if self.headers.get("X-API-Key") != "slsk-key": return self.j({"error": "nope"}, 401)
            r = p[len("/slskd/api/v0/"):]
            with LOCK:
                if r == "searches" and method == "POST":
                    b = json.loads(body); slsk_log.append(b["searchText"])
                    searches[b["id"]] = {"id": b["id"], "text": b["searchText"], "t": time.time()}
                    return self.j({"id": b["id"], "state": "InProgress", "isComplete": False})
                m = re.match(r"^searches/([\w-]+)(/responses)?$", r)
                if m:
                    s = searches.get(m.group(1))
                    if method == "DELETE": searches.pop(m.group(1), None); return self.j({}, 204)
                    if m.group(2): return self.j(SLSK_FILES.get(s["text"], []))
                    done = time.time() - s["t"] > 0.5
                    return self.j({"id": s["id"], "state": "Completed, TimedOut" if done else "InProgress", "isComplete": done})
                m = re.match(r"^transfers/downloads/([^/]+)$", r)
                if m:
                    user = m.group(1)
                    if method == "POST":
                        for f in json.loads(body):
                            transfers.setdefault(user, []).append({"id": f"t{len(transfers)}{len(f['filename'])}", "filename": f["filename"], "size": f["size"], "state": "Queued, Remotely"})
                        return self.j({}, 201)
                    for f in transfers.get(user, []): transfer_state(user, f)
                    return self.j({"username": user, "directories": [{"directory": "x", "files": transfers.get(user, [])}]})
            return self.j({"error": "?"}, 404)
        # Lidarr
        if p.startswith("/lidarr/api/v1/"):
            if self.headers.get("X-Api-Key") != "lid-key": return self.j({"error": "Unauthorized"}, 401)
            r = p[len("/lidarr/api/v1/"):]
            one = {k: v[0] for k, v in q.items()}
            lidarr_log.append((method, r, one))
            if r == "album" and method == "GET": return self.j([a for a in lidarr_albums if a["foreignAlbumId"] == one.get("foreignAlbumId")])
            if r == "album/lookup":
                rg = one["term"].replace("lidarr:", "")
                return self.j([{"foreignAlbumId": rg, "title": "Bon Iver, Bon Iver", "artist": {"foreignArtistId": "a-boniver", "artistName": "Bon Iver"}}])
            if r == "rootfolder": return self.j([{"id": 1, "path": "/music", "defaultQualityProfileId": 2, "defaultMetadataProfileId": 1}])
            if r == "album" and method == "POST":
                a = json.loads(body); a["id"] = len(lidarr_albums) + 1; lidarr_albums.append(a)
                assert a["artist"]["rootFolderPath"] == "/music" and a["artist"]["qualityProfileId"] == 2 and a["addOptions"]["searchForNewAlbum"]
                threading.Thread(target=lidarr_download, args=(a,), daemon=True).start()
                return self.j(a, 201)
            if r in ("album/monitor", "command"): return self.j({}, 202)
            return self.j({"error": "?"}, 404)
        # MusicBrainz
        if p == "/ws/2/recording":
            query = one = q.get("query", [""])[0].lower()
            for k, v in MB.items():
                if k in query: return self.j(v)
            return self.j({"recordings": []})
        if p == "/_state":
            with LOCK:
                return self.j({"playlists": playlists, "slsk": slsk_log, "lidarr": lidarr_log, "songs": len(songs)})
        self.send_response(404); self.end_headers()

    def do_GET(self): self.handle_req("GET")
    def do_POST(self): self.handle_req("POST")
    def do_PUT(self): self.handle_req("PUT")
    def do_DELETE(self): self.handle_req("DELETE")

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
