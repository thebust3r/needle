"""Needle helper: turns a Spotify playlist (or a pasted song list) into a Navidrome playlist,
and fetches the missing songs through slskd (just the song) or Lidarr (the whole album).

Runs on the NAS next to the web player. Standard library only. Settings come from the
environment (see docker-compose.yml). The web player and the iPhone app talk to it at /helper/.
"""
import csv
import difflib
import hashlib
import html
import io
import json
import os
import re
import shutil
import sys
import threading
import time
import unicodedata
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, urlencode, urlparse
from urllib.request import Request, urlopen

VERSION = "1.1"
E = os.environ.get
NAVIDROME = E("NAVIDROME_URL", "http://192.168.1.168:4533").rstrip("/")
SLSKD = E("SLSKD_URL", "").rstrip("/")
SLSKD_KEY = E("SLSKD_API_KEY", "")
LIDARR = E("LIDARR_URL", "").rstrip("/")
LIDARR_KEY = E("LIDARR_API_KEY", "")
SPOTIFY = E("SPOTIFY_URL", "https://open.spotify.com").rstrip("/")
MUSICBRAINZ = E("MUSICBRAINZ_URL", "https://musicbrainz.org").rstrip("/")
MUSIC_DIR = E("MUSIC_DIR", "/music")
DOWNLOADS_DIR = E("DOWNLOADS_DIR", "/downloads")
DATA_DIR = E("DATA_DIR", "/app/helper-data")
SONGS_FOLDER = E("SONGS_FOLDER", "Needle Downloads")
PORT = int(E("PORT", "8790"))
FAST = E("NEEDLE_FAST") == "1"          # tests: shorter waits
TICK = 0.2 if FAST else 2.0
SEARCH_WAIT = 3 if FAST else 25          # seconds to let a Soulseek search collect answers
MAX_SEARCHING = 3                        # Soulseek searches at once
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
AUDIO = {"flac", "mp3", "m4a", "aac", "ogg", "opus", "wav", "alac", "aiff", "aif", "wma"}

os.umask(0)   # downloaded files stay editable from UGREEN Files


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ------------------------------------------------------------------ text matching

VARIANTS = ["remix", "live", "acoustic", "instrumental", "acapella", "a cappella", "karaoke", "demo",
            "sped up", "slowed", "reverb", "nightcore", "cover", "8d", "chopped", "screwed"]
NOISE = re.compile(r"\b(feat|ft|featuring|with|remaster(ed)?|version|radio edit|single|album|mono|stereo|explicit|clean|"
                   r"bonus( track)?|deluxe|edition|from|original( mix)?|\d{4})\b")


def norm(s):
    s = unicodedata.normalize("NFKD", str(s or "")).encode("ascii", "ignore").decode().lower()
    s = s.replace("&", " and ").replace("'", "").replace("’", "")
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return " ".join(s.split())


def variant_words(s):
    n = " " + norm(s) + " "
    return {v for v in VARIANTS if f" {v} " in n}


def clean_title(t):
    """Drops the parts streaming services add: (feat. X), - Remastered 2011, [Explicit], etc."""
    t = str(t or "")
    keep = []
    for m in re.finditer(r"[\(\[]([^\)\]]*)[\)\]]", t):
        inner = m.group(1)
        if variant_words(inner) and not NOISE.search(norm(inner)):
            keep.append(inner)
    t = re.sub(r"[\(\[][^\)\]]*[\)\]]", " ", t)
    parts = re.split(r"\s+[-–—]\s+", t)
    base = parts[0]
    for p in parts[1:]:
        if variant_words(p) and not re.search(r"remaster", p, re.I):
            keep.append(p)
    t = " ".join([base] + keep)
    t = re.sub(r"\b(feat|ft|featuring)\.?\s.*$", "", t, flags=re.I)
    return norm(t)


def strip_track_no(t):
    return re.sub(r"^\s*(\d{1,3}|[a-dA-D]\d{1,2})(\s*[-._)]\s*|\s+)", "", t)


def title_score(want, got):
    """How alike two titles are (0..1). Tries the title as-is and with a leading track number removed,
    so '04 - Midnight City' matches but '7 Rings' still needs its 7."""
    a = clean_title(want)
    best = 0.0
    for b in {clean_title(got), clean_title(strip_track_no(str(got or "")))}:
        if not a or not b:
            continue
        if a == b:
            return 1.0
        sc = 0.98 if set(a.split()) == set(b.split()) else difflib.SequenceMatcher(None, a, b).ratio()
        best = max(best, sc)
    return best


def artist_names(s):
    """Every reasonable way an artist field can be split: 'A, B', 'A feat. B', 'A & B'."""
    whole = norm(s)
    out = {whole} if whole else set()
    for part in re.split(r",|;|/|\bfeat\.?\b|\bft\.?\b|\bfeaturing\b|\bwith\b|&|\band\b|\bx\b|•", str(s or ""), flags=re.I):
        p = norm(part)
        if p:
            out.add(p)
    return {re.sub(r"^the ", "", x) for x in out}


def artist_ok(wanted, song):
    have = set()
    for f in (song.get("artist"), song.get("albumArtist"), song.get("displayArtist")):
        have |= artist_names(f)
    for a in song.get("artists") or []:
        have |= artist_names(a.get("name"))
    for w in wanted:
        for x in artist_names(w):
            for h in have:
                if x == h or (len(x) > 3 and (x in h or h in x)) or difflib.SequenceMatcher(None, x, h).ratio() > 0.86:
                    return True
    return False


def song_score(t, s):
    ts = title_score(t["title"], s.get("title", ""))
    if variant_words(t["title"]) != variant_words(s.get("title", "")):
        ts -= 0.25
    if t.get("duration") and s.get("duration"):
        if abs(t["duration"] - s["duration"]) > 15:
            ts -= 0.12
    if t["artists"]:
        if not artist_ok(t["artists"], s):
            return 0.0
    elif ts < 0.97:
        return 0.0
    return ts


# ------------------------------------------------------------------ http helpers

def http(url, method="GET", body=None, headers=None, timeout=30, raw=False):
    h = {"User-Agent": "Needle helper/" + VERSION}
    h.update(headers or {})
    data = None
    if body is not None:
        if isinstance(body, (dict, list)):
            data = json.dumps(body).encode()
            h.setdefault("Content-Type", "application/json")
        elif isinstance(body, str):
            data = body.encode()
        else:
            data = body
    req = Request(url, data=data, method=method, headers=h)
    with urlopen(req, timeout=timeout) as r:
        b = r.read()
        if raw:
            return b
        if not b:
            return None
        return json.loads(b)


class Navidrome:
    def __init__(self, creds):
        self.creds = creds

    def params(self, extra):
        p = [("u", self.creds["u"]), ("t", self.creds["t"]), ("s", self.creds["s"]), ("v", "1.16.1"), ("c", "NeedleHelper"), ("f", "json")]
        for k, v in extra:
            p.append((k, v))
        return urlencode(p)

    def call(self, ep, extra=(), post=False):
        url = f"{NAVIDROME}/rest/{ep}"
        if post:
            res = http(url, "POST", self.params(extra), {"Content-Type": "application/x-www-form-urlencoded"})
        else:
            res = http(url + "?" + self.params(extra))
        r = (res or {}).get("subsonic-response") or {}
        if r.get("status") != "ok":
            raise RuntimeError((r.get("error") or {}).get("message") or "Navidrome said no")
        return r

    def search(self, q, n=40):
        r = self.call("search3", [("query", q), ("songCount", n), ("albumCount", 0), ("artistCount", 0)])
        return (r.get("searchResult3") or {}).get("song") or []

    def save_playlist(self, pid, name, song_ids):
        extra = [("songId", s) for s in song_ids]
        if pid:
            self.call("createPlaylist", [("playlistId", pid)] + extra, post=True)
            return pid
        r = self.call("createPlaylist", [("name", name)] + extra, post=True)
        if r.get("playlist", {}).get("id"):
            return r["playlist"]["id"]
        lists = (self.call("getPlaylists").get("playlists") or {}).get("playlist") or []
        mine = [p for p in lists if p.get("name") == name]
        mine.sort(key=lambda p: p.get("created", ""), reverse=True)
        return mine[0]["id"] if mine else None

    def scan(self):
        try:
            self.call("startScan")
        except Exception:
            pass   # needs an admin account; Navidrome also notices new files by itself


AUTH_CACHE = {}


def check_auth(q):
    creds = {k: (q.get(k) or [""])[0] for k in ("u", "t", "s")}
    if not all(creds.values()):
        return None
    key = (creds["u"], creds["t"], creds["s"])
    if AUTH_CACHE.get(key, 0) > time.time():
        return creds
    try:
        Navidrome(creds).call("ping")
    except Exception:
        return None
    AUTH_CACHE[key] = time.time() + 600
    return creds


def find_in_library(nav, t):
    """Best matching song in Navidrome for a playlist entry, or None."""
    title = clean_title(t["title"])
    if not title:
        return None
    queries = [title]
    if t["artists"]:
        queries.append(norm(t["artists"][0]) + " " + title)
    if t.get("file"):
        queries.append(strip_track_no(norm(os.path.splitext(os.path.basename(t["file"]))[0])))
    best, best_s = None, 0.0
    for q in queries:
        try:
            songs = nav.search(q)
        except Exception as e:
            raise RuntimeError(f"Couldn't search your library: {e}")
        for s in songs:
            sc = song_score(t, s)
            if t.get("file") and str(s.get("path", "")).replace("\\", "/").endswith(os.path.basename(t["file"])):
                sc = max(sc, 1.0)
            if sc > best_s:
                best, best_s = s, sc
        if best_s >= 0.97:
            break
    return best if best_s >= 0.86 else None


# ------------------------------------------------------------------ reading playlists

class ReadError(Exception):
    pass


def spotify_link(text):
    m = re.search(r"(?:open\.spotify\.com/(?:intl-[a-z-]+/)?(?:embed/)?|spotify:)(playlist|album|track)[/:]([A-Za-z0-9]{10,})", text)
    return (m.group(1), m.group(2)) if m else None


def find_key(obj, key):
    if isinstance(obj, dict):
        if key in obj and isinstance(obj[key], list):
            return obj
        for v in obj.values():
            r = find_key(v, key)
            if r is not None:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = find_key(v, key)
            if r is not None:
                return r
    return None


def split_artists(s):
    s = str(s or "").replace(" ", " ")
    parts = [p.strip() for p in re.split(r",\s*|\s+•\s+", s) if p.strip()]
    out = [s.strip()] if s.strip() else []
    for p in parts:
        if p not in out:
            out.append(p)
    return out


def read_spotify(kind, sid):
    url = f"{SPOTIFY}/embed/{kind}/{sid}"
    try:
        page = http(url, headers={"User-Agent": UA, "Accept-Language": "en-US,en;q=0.9"}, raw=True, timeout=25).decode("utf-8", "replace")
    except HTTPError as e:
        if e.code in (400, 404):
            raise ReadError("Spotify says that playlist doesn't exist. Check the link, and make sure the playlist is public.")
        raise ReadError(f"Spotify answered with error {e.code}. Try again in a minute.")
    except (URLError, OSError) as e:
        raise ReadError(f"Couldn't reach Spotify from the NAS ({getattr(e, 'reason', e)}).")
    data = None
    m = re.search(r'<script[^>]*id="__NEXT_DATA__"[^>]*>(.*?)</script>', page, re.S)
    if m:
        try:
            data = json.loads(html.unescape(m.group(1)) if m.group(1).lstrip().startswith("&") else m.group(1))
        except ValueError:
            data = None
    entity = find_key(data, "trackList") if data is not None else None
    if entity is None:
        i = page.find('"trackList":')
        if i >= 0:
            try:
                lst, _ = json.JSONDecoder().raw_decode(page[i + len('"trackList":'):])
                entity = {"trackList": lst}
                nm = re.search(r'"name":"((?:[^"\\]|\\.)*)"', page)
                if nm:
                    entity["name"] = json.loads('"' + nm.group(1) + '"')
            except ValueError:
                entity = None
    if entity is None:
        raise ReadError("Couldn't read that playlist from Spotify's page (they may have changed it). Paste the song list instead.")
    tracks = []
    for it in entity["trackList"]:
        if not isinstance(it, dict):
            continue
        title = it.get("title") or it.get("name")
        if not title:
            continue
        artists = []
        if isinstance(it.get("artists"), list):
            artists = [a.get("name") if isinstance(a, dict) else str(a) for a in it["artists"]]
            artists = [a for a in artists if a]
        if not artists:
            artists = split_artists(it.get("subtitle"))
        dur = it.get("duration") or it.get("duration_ms") or 0
        tracks.append({"title": title, "artists": artists, "duration": round(dur / 1000) if dur > 1000 else dur, "uri": it.get("uri", "")})
    name = entity.get("name") or entity.get("title") or "Spotify playlist"
    if not tracks:
        raise ReadError("That playlist looks empty on Spotify.")
    return name, tracks


def read_text(text):
    lines = [l for l in text.replace("\r", "").split("\n") if l.strip()]
    if not lines:
        raise ReadError("Paste a Spotify link or a list of songs.")
    head = lines[0].lower()
    tracks = []
    if "track name" in head or ("title" in head and "artist" in head and "," in head):
        rows = list(csv.DictReader(io.StringIO("\n".join(lines))))
        for r in rows:
            low = {k.lower().strip(): (v or "") for k, v in r.items() if k}
            title = low.get("track name") or low.get("title") or low.get("name")
            art = low.get("artist name(s)") or low.get("artist name") or low.get("artists") or low.get("artist") or ""
            dur = low.get("duration (ms)") or low.get("track duration (ms)") or "0"
            if title:
                arts = [a.strip() for a in re.split(r",|;", art) if a.strip()]
                if art.strip() and art.strip() not in arts:
                    arts.insert(0, art.strip())
                try:
                    d = round(int(float(dur)) / 1000)
                except ValueError:
                    d = 0
                tracks.append({"title": title.strip(), "artists": arts, "duration": d, "album": low.get("album name", "")})
    else:
        for l in lines:
            l = re.sub(r"^\s*(\d+[.)]\s+|[-*•]\s+)", "", l).strip()
            m = re.split(r"\s+[-–—]\s+", l, maxsplit=1)
            if len(m) == 2:
                tracks.append({"title": m[1].strip(), "artists": split_artists(m[0]), "duration": 0})
            else:
                bm = re.match(r"(.+?)\s+by\s+(.+)$", l, re.I)
                if bm:
                    tracks.append({"title": bm.group(1).strip(), "artists": split_artists(bm.group(2)), "duration": 0})
                else:
                    tracks.append({"title": l, "artists": [], "duration": 0})
    if not tracks:
        raise ReadError("Couldn't find any songs in that text. Use one song per line, like: Artist - Song")
    return tracks


# ------------------------------------------------------------------ jobs

LOCK = threading.RLock()
JOBS = {}
JOBS_FILE = os.path.join(DATA_DIR, "jobs.json")
ACTIVE = {"searching", "downloading", "importing", "queued", "requesting", "album"}


# ------------------------------------------------------------------ listening history (shared by the app and the web)
# Every play from every device, per Navidrome user, so Wrapped and the mixes see all your listening.

HISTORY_LOCK = threading.Lock()
HISTORY_MAX = 50000
HISTORY_FIELDS = ("id", "title", "artist", "album", "albumId", "coverArt", "duration", "at", "listened", "speed", "device")


def history_file(user):
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", user)[:60] or "user"
    return os.path.join(DATA_DIR, f"history-{safe}.json")


def load_history(user):
    try:
        with open(history_file(user)) as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


def merge_history(user, plays):
    """Adds or updates plays (the same play from the same device = same device + start time). Returns how many changed."""
    with HISTORY_LOCK:
        have = load_history(user)
        index = {(r.get("device"), r.get("at")): i for i, r in enumerate(have)}
        changed = 0
        for p in plays:
            if not isinstance(p, dict) or not p.get("id") or not isinstance(p.get("at"), (int, float)):
                continue
            rec = {k: p.get(k) for k in HISTORY_FIELDS if p.get(k) is not None}
            key = (rec.get("device"), rec.get("at"))
            if key in index:
                if have[index[key]] != rec:
                    have[index[key]].update(rec); changed += 1
            else:
                index[key] = len(have); have.append(rec); changed += 1
        if changed:
            have.sort(key=lambda r: r.get("at", 0))
            have = have[-HISTORY_MAX:]
            tmp = history_file(user) + ".tmp"
            with open(tmp, "w") as f:
                json.dump(have, f, separators=(",", ":"))
            os.replace(tmp, history_file(user))
        return changed


def save_jobs():
    with LOCK:
        os.makedirs(DATA_DIR, exist_ok=True)
        tmp = JOBS_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(JOBS, f)
        os.replace(tmp, JOBS_FILE)


def load_jobs():
    try:
        with open(JOBS_FILE) as f:
            JOBS.update(json.load(f))
    except (OSError, ValueError):
        pass
    for j in JOBS.values():
        if j.get("state") in ("reading", "matching"):
            j["state"], j["error"] = "error", "The helper restarted while this was running. Import it again."


def public(job):
    j = {k: v for k, v in job.items() if k != "creds"}
    j["tracks"] = [{k: v for k, v in t.items() if not k.startswith("_")} for t in job.get("tracks", [])]
    c = {}
    for t in job.get("tracks", []):
        c[t["status"]] = c.get(t["status"], 0) + 1
    j["counts"] = c
    j["found"] = c.get("found", 0)
    j["active"] = any(t["status"] in ACTIVE for t in job.get("tracks", []))
    return j


def touch(job):
    job["updated"] = time.time()


def rebuild_playlist(job):
    nav = Navidrome(job["creds"])
    ids = [t["songId"] for t in job["tracks"] if t.get("songId")]
    job["playlistId"] = nav.save_playlist(job.get("playlistId"), job["name"], ids)


def run_import(job_id, source, name):
    with LOCK:
        job = JOBS[job_id]
    try:
        link = spotify_link(source)
        if link and link[0] == "track":
            raise ReadError("That's a link to one song. Paste a playlist or album link.")
        if link:
            sp_name, tracks = read_spotify(*link)
            job["name"] = name or sp_name
            if len(tracks) == 100 and link[0] == "playlist":
                job["note"] = ("Spotify only shares the first 100 songs of a playlist this way. "
                               "To get the rest, paste the full song list (one 'Artist - Song' per line, or an Exportify CSV).")
        else:
            tracks = read_text(source)
            job["name"] = name or "Imported " + time.strftime("%b %-d")
        job["tracks"] = [dict(t, i=i, status="matching") for i, t in enumerate(tracks)]
        job["state"] = "matching"
        job["progress"] = {"done": 0, "total": len(tracks)}
        touch(job)
        nav = Navidrome(job["creds"])
        for t in job["tracks"]:
            s = find_in_library(nav, t)
            if s:
                t.update(status="found", songId=s["id"], match=f'{s.get("artist", "")} - {s.get("title", "")}')
            else:
                t["status"] = "missing"
            job["progress"]["done"] += 1
            touch(job)
        rebuild_playlist(job)
        job["state"] = "ready"
    except ReadError as e:
        job["state"], job["error"] = "error", str(e)
    except Exception as e:
        log("import failed:", repr(e))
        job["state"], job["error"] = "error", f"Something went wrong: {e}"
    touch(job)
    save_jobs()


def start_downloads(job, method, which):
    for t in job["tracks"]:
        if t["i"] not in which or t["status"] not in ("missing", "failed"):
            continue
        for k in [k for k in t if k.startswith("_")] + ["note", "progress", "file"]:
            t.pop(k, None)
        t["method"] = method
        t["status"] = "queued" if method == "song" else "requesting"
        t["_next"] = 0
    touch(job)
    save_jobs()


# ------------------------------------------------------------------ Soulseek (slskd)

def slskd(path, method="GET", body=None):
    return http(f"{SLSKD}/api/v0/{path}", method, body, {"X-API-Key": SLSKD_KEY}, timeout=20)


def primary_artist(t):
    a = t["artists"]
    if not a:
        return ""
    return a[1] if len(a) > 1 and ("," in a[0] or "\u2022" in a[0]) else a[0]


def slsk_query(t, title_only=False):
    title = clean_title(t["title"])
    if title_only or not t["artists"]:
        return title
    artist = re.sub(r"^the ", "", norm(primary_artist(t)))
    return f"{artist} {title}"


def pick_files(t, responses):
    want = set(clean_title(t["title"]).split())
    wanted_variants = variant_words(t["title"])
    arts = set()
    for a in t["artists"]:
        arts |= artist_names(a)
    picks = []
    for r in responses or []:
        user = r.get("username")
        for f in r.get("files") or []:
            fn = f.get("filename", "")
            ext = (f.get("extension") or fn.rsplit(".", 1)[-1]).lower().lstrip(".")
            if ext not in AUDIO or f.get("isLocked"):
                continue
            path = fn.replace("\\", "/")
            base = os.path.splitext(path.rsplit("/", 1)[-1])[0]
            bn = norm(base)
            if not want <= set(bn.split()):
                continue
            if variant_words(base) - wanted_variants:
                continue
            if t.get("duration") and f.get("length") and abs(f["length"] - t["duration"]) > 10:
                continue
            fullp = " " + norm(path) + " "
            has_artist = any(f" {a} " in fullp for a in arts) if arts else False
            if arts and not has_artist and not t.get("_title_only_ok"):
                continue
            extra = len(bn.split()) - len(want)
            score = 0.0
            br = f.get("bitRate") or 0
            score += 3 if ext == "flac" else 3 if br >= 300 else 2 if br >= 250 or ext in ("m4a", "aac", "ogg", "opus") else 1
            score += 3 if r.get("hasFreeUploadSlot") else 0
            score += min(2, (r.get("uploadSpeed") or 0) / 1_000_000)
            score -= min(3, (r.get("queueLength") or 0) / 10)
            score += 1 if has_artist else 0
            score -= min(2, max(0, extra - 3) * 0.3)
            picks.append((score, {"user": user, "filename": fn, "size": f.get("size", 0)}))
    picks.sort(key=lambda p: -p[0])
    out, users = [], set()
    for _, p in picks:
        if p["user"] in users:
            continue
        users.add(p["user"])
        out.append(p)
        if len(out) == 4:
            break
    return out


def safe_name(s):
    s = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", str(s or "")).strip(" .")
    return s[:120] or "Unknown"


def find_download(filename, size):
    base = filename.replace("\\", "/").rsplit("/", 1)[-1]
    best = None
    for root, _, files in os.walk(DOWNLOADS_DIR):
        if base in files:
            p = os.path.join(root, base)
            try:
                st = os.stat(p)
            except OSError:
                continue
            if size and st.st_size != size:
                continue
            if best is None or st.st_mtime > best[0]:
                best = (st.st_mtime, p)
    return best[1] if best else None


def move_into_library(t, src):
    artist = primary_artist(t) or "Unknown Artist"
    dest_dir = os.path.join(MUSIC_DIR, SONGS_FOLDER, safe_name(artist))
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, safe_name(os.path.basename(src)))
    if not os.path.exists(dest):
        shutil.move(src, dest)
        try:
            os.chmod(dest, 0o666)
        except OSError:
            pass
    else:
        os.remove(src)
    parent = os.path.dirname(src)
    try:
        if os.path.abspath(parent) != os.path.abspath(DOWNLOADS_DIR) and not os.listdir(parent):
            os.rmdir(parent)
    except OSError:
        pass
    return os.path.relpath(dest, MUSIC_DIR)


def step_song(job, t, now):
    st = t["status"]
    if st == "queued":
        busy = sum(1 for j in JOBS.values() for x in j["tracks"] if x["status"] == "searching")
        if busy >= MAX_SEARCHING:
            t["_next"] = now + TICK
            return
        q = slsk_query(t, t.get("_title_only_ok", False))
        sid = str(uuid.uuid4())
        slskd("searches", "POST", {"id": sid, "searchText": q, "searchTimeout": SEARCH_WAIT * 1000, "filterResponses": True,
                                     "responseLimit": 200, "fileLimit": 20000})
        t.update(status="searching", _search=sid, _since=now, _q=q, note="Searching Soulseek")
        t["_next"] = now + (1 if FAST else 5)
    elif st == "searching":
        s = slskd(f"searches/{t['_search']}")
        done = (s or {}).get("isComplete") or "Completed" in str((s or {}).get("state", ""))
        if not done and now - t["_since"] < SEARCH_WAIT + 10:
            t["_next"] = now + (0.5 if FAST else 4)
            return
        responses = slskd(f"searches/{t['_search']}/responses") or []
        try:
            slskd(f"searches/{t['_search']}", "DELETE")
        except Exception:
            pass
        picks = pick_files(t, responses)
        if not picks and not t.get("_title_only_ok") and t["artists"] and len(clean_title(t["title"])) >= 8:
            t.update(status="queued", _title_only_ok=True, note="Trying another search")
            t["_next"] = now
            return
        if not picks:
            t.update(status="failed", note="No one on Soulseek is sharing it right now (or Soulseek blocks this artist's name)")
            return
        t["_picks"] = picks
        t["_try"] = -1
        next_pick(t, now)
    elif st == "downloading":
        p = t["_picks"][t["_try"]]
        info = slskd(f"transfers/downloads/{quote(p['user'])}") or {}
        f = None
        for d in info.get("directories") or []:
            for x in d.get("files") or []:
                if x.get("filename") == p["filename"]:
                    f = x
        state = str((f or {}).get("state", ""))
        if f and "Succeeded" in state:
            src = find_download(p["filename"], p.get("size"))
            if not src:
                if now - t.get("_done_since", now) > 120:
                    t.update(status="failed", note="slskd says it finished, but the file isn't in the downloads folder the helper can see. "
                                                   "Check the downloads folder path in the compose file.")
                    return
                t.setdefault("_done_since", now)
                t["_next"] = now + TICK * 2
                return
            t["file"] = move_into_library(t, src)
            t.update(status="importing", note="Adding to your library", _since=now, progress=100)
            Navidrome(job["creds"]).scan()
            t["_next"] = now + (0.5 if FAST else 10)
        elif f and "Completed" in state:
            next_pick(t, now, f"{p['user']}'s copy failed ({state.split(',')[-1].strip()})")
        else:
            if f:
                t["progress"] = round(f.get("percentComplete") or 0)
                t["note"] = "Waiting in their queue" if "Queued" in state else "Downloading"
                if "InProgress" in state:
                    t["_moving"] = now
            if now - max(t["_since"], t.get("_moving", 0)) > (20 if FAST else 900):
                try:
                    slskd(f"transfers/downloads/{quote(p['user'])}/{f['id']}?remove=true", "DELETE") if f and f.get("id") else None
                except Exception:
                    pass
                next_pick(t, now, f"{p['user']} took too long")
                return
            t["_next"] = now + (0.5 if FAST else 5)
    elif st == "importing":
        s = find_in_library(Navidrome(job["creds"]), t)
        if s:
            t.update(status="found", songId=s["id"], match=f'{s.get("artist", "")} - {s.get("title", "")}', note="Downloaded")
            rebuild_playlist(job)
            return
        if now - t["_since"] > (6 if FAST else 3600):
            t.update(status="failed", note=f"Downloaded to Music/{t.get('file', '')}, but Navidrome hasn't added it yet. "
                                           "It'll show up after the next library scan; import the playlist again to slot it in.")
            return
        t["_next"] = now + (0.5 if FAST else 20)


def next_pick(t, now, why=None):
    t["_try"] = t.get("_try", -1) + 1
    picks = t.get("_picks") or []
    if t["_try"] >= len(picks):
        t.update(status="failed", note=f"{why}, and no one else had it. Try again later." if why else "No one had a copy that worked. Try again later.")
        return
    p = picks[t["_try"]]
    slskd(f"transfers/downloads/{quote(p['user'])}", "POST", [{"filename": p["filename"], "size": p["size"]}])
    t.update(status="downloading", _since=now, progress=0, note=f"Downloading from {p['user']}")
    t.pop("_done_since", None)
    t["_next"] = now + (0.5 if FAST else 4)


# ------------------------------------------------------------------ Lidarr (whole album)

MB_LAST = [0.0]


def musicbrainz(path):
    wait = MB_LAST[0] + 1.1 - time.time()
    if wait > 0 and not FAST:
        time.sleep(wait)
    MB_LAST[0] = time.time()
    return http(f"{MUSICBRAINZ}/ws/2/{path}", headers={"User-Agent": f"NeedleHelper/{VERSION} (self-hosted music player)",
                                                         "Accept": "application/json"})


def album_for(t):
    """MusicBrainz release group (album) that has this song: prefers studio albums, then EPs, then singles."""
    def q(s):
        return '"' + str(s).replace('"', " ") + '"'
    title = re.sub(r"\s+", " ", re.sub(r"\(.*?\)|\[.*?\]", "", t["title"])).strip()
    query = f"recording:{q(title)}"
    if t["artists"]:
        query += f" AND artist:{q(primary_artist(t))}"
    data = musicbrainz("recording?" + urlencode({"query": query, "fmt": "json", "limit": 15}))
    best = None
    for rec in (data or {}).get("recordings") or []:
        if int(rec.get("score", 0)) < 85 or title_score(t["title"], rec.get("title", "")) < 0.86:
            continue
        for rel in rec.get("releases") or []:
            rg = rel.get("release-group") or {}
            if not rg.get("id"):
                continue
            ptype = rg.get("primary-type") or ""
            sec = rg.get("secondary-types") or []
            rank = {"Album": 0, "EP": 1, "Single": 2}.get(ptype, 3) + (3 if sec else 0) + (0 if rel.get("status", "Official") == "Official" else 1)
            date = rel.get("date") or "9999"
            key = (rank, date)
            if best is None or key < best[0]:
                best = (key, rg["id"], rg.get("title") or rel.get("title"))
    return (best[1], best[2]) if best else (None, None)


def lidarr(path, method="GET", body=None):
    return http(f"{LIDARR}/api/v1/{path}", method, body, {"X-Api-Key": LIDARR_KEY}, timeout=60)


def request_album(rgid):
    existing = lidarr("album?" + urlencode({"foreignAlbumId": rgid})) or []
    existing = [a for a in existing if a.get("foreignAlbumId") == rgid]
    if existing:
        a = existing[0]
        lidarr("album/monitor", "PUT", {"albumIds": [a["id"]], "monitored": True})
        lidarr("command", "POST", {"name": "AlbumSearch", "albumIds": [a["id"]]})
        return a.get("title")
    found = lidarr("album/lookup?" + urlencode({"term": "lidarr:" + rgid})) or []
    if not found:
        raise RuntimeError("Lidarr couldn't find that album in its catalog")
    album = found[0]
    roots = lidarr("rootfolder") or []
    if not roots:
        raise RuntimeError("Lidarr has no music folder yet (Settings > Media Management > Root Folders)")
    root = roots[0]
    qp = root.get("defaultQualityProfileId") or ((lidarr("qualityprofile") or [{}])[0].get("id"))
    mp = root.get("defaultMetadataProfileId") or ((lidarr("metadataprofile") or [{}])[0].get("id"))
    artist = dict(album.get("artist") or {})
    artist.update(qualityProfileId=qp, metadataProfileId=mp, rootFolderPath=root.get("path"), monitored=True,
                  monitorNewItems="none", addOptions={"monitor": "none", "searchForMissingAlbums": False})
    album.update(monitored=True, artist=artist, addOptions={"searchForNewAlbum": True})
    lidarr("album", "POST", album)
    return album.get("title")


def step_album(job, t, now):
    if t["status"] == "requesting":
        rgid, title = album_for(t)
        if not rgid:
            t.update(status="failed", note="Couldn't work out which album this song is on. Try 'Just the songs' instead.")
            return
        asked = job.setdefault("albumsRequested", {})
        if rgid not in asked:
            try:
                asked[rgid] = request_album(rgid) or title
            except HTTPError as e:
                msg = e.read().decode("utf-8", "replace")[:200]
                t.update(status="failed", note=f"Lidarr said no: {msg or e.code}")
                return
        t.update(status="album", note=f"Lidarr is getting the album {asked[rgid] or title}", _since=now, _album=rgid)
        t["_next"] = now + (0.5 if FAST else 60)
    elif t["status"] == "album":
        s = find_in_library(Navidrome(job["creds"]), t)
        if s:
            t.update(status="found", songId=s["id"], match=f'{s.get("artist", "")} - {s.get("title", "")}', note="Downloaded with the album")
            rebuild_playlist(job)
            return
        if now - t["_since"] > (6 if FAST else 6 * 3600):
            t.update(status="failed", note="Lidarr hasn't finished this album after 6 hours. Check Activity in Lidarr.")
            return
        t["_next"] = now + (0.5 if FAST else 60)


# ------------------------------------------------------------------ background worker

def worker():
    while True:
        time.sleep(TICK)
        now = time.time()
        changed = False
        with LOCK:
            jobs = list(JOBS.values())
        for job in jobs:
            for t in job.get("tracks", []):
                if t["status"] not in ACTIVE or t.get("_next", 0) > now:
                    continue
                before = (t["status"], t.get("note"), t.get("progress"))
                try:
                    (step_song if t.get("method") == "song" else step_album)(job, t, now)
                except (HTTPError, URLError, OSError, RuntimeError, ValueError) as e:
                    t["_errors"] = t.get("_errors", 0) + 1
                    what = "Lidarr" if t.get("method") == "album" else "slskd"
                    if isinstance(e, HTTPError) and e.code == 401:
                        t.update(status="failed", note=f"{what} rejected the API key in the compose file.")
                    elif t["_errors"] >= 5:
                        t.update(status="failed", note=f"Couldn't talk to {what}: {getattr(e, 'reason', e)}")
                    else:
                        t["_next"] = now + (0.3 if FAST else 15)
                    log("step error", t["title"], repr(e))
                if before != (t["status"], t.get("note"), t.get("progress")):
                    touch(job)
                    changed = True
        if changed:
            save_jobs()


def watch_self():
    """Restarts the helper when an update replaces this file (the container loop starts it again)."""
    me = os.path.abspath(__file__)
    try:
        start = os.path.getmtime(me)
    except OSError:
        return
    while True:
        time.sleep(5)
        try:
            m = os.path.getmtime(me)
        except OSError:
            continue   # mid-swap
        if m != start:
            time.sleep(2)
            log("Helper file changed, restarting with the new version")
            save_jobs()
            os._exit(3)


# ------------------------------------------------------------------ web API

class Handler(BaseHTTPRequestHandler):
    server_version = "NeedleHelper/" + VERSION

    def log_message(self, *a):
        pass

    def send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(b)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 2_000_000:
            raise ValueError("too big")
        raw = self.rfile.read(n) if n else b""
        return json.loads(raw) if raw else {}

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def route(self, method):
        u = urlparse(self.path)
        path = u.path
        if path.startswith("/helper"):
            path = path[len("/helper"):]
        path = path.rstrip("/") or "/"
        q = parse_qs(u.query)
        if path == "/ping":
            return self.send(200, {"ok": True, "version": VERSION})
        creds = check_auth(q)
        if not creds:
            return self.send(401, {"error": "Sign in with your Navidrome account."})
        if path == "/status" and method == "GET":
            return self.send(200, {"ok": True, "version": VERSION, "soulseek": bool(SLSKD and SLSKD_KEY), "lidarr": bool(LIDARR and LIDARR_KEY)})
        if path == "/jobs" and method == "GET":
            with LOCK:
                mine = [public(j) for j in JOBS.values() if j["creds"]["u"] == creds["u"]]
            mine.sort(key=lambda j: -j["created"])
            for j in mine:
                j.pop("tracks")
            return self.send(200, {"jobs": mine})
        if path == "/import" and method == "POST":
            b = self.body()
            src = str(b.get("source") or "").strip()
            if not src:
                return self.send(400, {"error": "Paste a Spotify link or a list of songs."})
            jid = uuid.uuid4().hex[:10]
            job = {"id": jid, "created": time.time(), "updated": time.time(), "state": "reading", "name": str(b.get("name") or "").strip()[:100],
                   "source": src[:300], "tracks": [], "creds": creds, "progress": {"done": 0, "total": 0}}
            with LOCK:
                JOBS[jid] = job
                for old in sorted(JOBS.values(), key=lambda j: j["created"])[:-40]:
                    JOBS.pop(old["id"], None)
            threading.Thread(target=run_import, args=(jid, src, job["name"]), daemon=True).start()
            return self.send(200, public(job))
        if path == "/history" and method == "GET":
            since = float((q.get("since") or ["0"])[0] or 0)
            plays = [r for r in load_history(creds["u"]) if r.get("at", 0) > since]
            return self.send(200, {"plays": plays})
        if path == "/history" and method == "POST":
            b = self.body()
            plays = b.get("plays") if isinstance(b, dict) else None
            if not isinstance(plays, list):
                return self.send(400, {"error": "Send {plays: [...]}"})
            return self.send(200, {"ok": True, "changed": merge_history(creds["u"], plays[:2000])})
        m = re.fullmatch(r"/jobs/([0-9a-f]+)(/download|/rematch)?", path)
        if m:
            with LOCK:
                job = JOBS.get(m.group(1))
            if not job or job["creds"]["u"] != creds["u"]:
                return self.send(404, {"error": "That import isn't here anymore."})
            job["creds"] = creds   # keep the newest working login for background updates
            action = m.group(2)
            if method == "GET" and not action:
                return self.send(200, public(job))
            if method == "DELETE" and not action:
                with LOCK:
                    JOBS.pop(job["id"], None)
                save_jobs()
                return self.send(200, {"ok": True})
            if method == "POST" and action == "/download":
                b = self.body()
                how = b.get("method")
                if how == "song" and not (SLSKD and SLSKD_KEY):
                    return self.send(400, {"error": "Soulseek isn't set up in the helper. Add SLSKD_URL and SLSKD_API_KEY to the compose file."})
                if how == "album" and not (LIDARR and LIDARR_KEY):
                    return self.send(400, {"error": "Lidarr isn't set up in the helper. Add LIDARR_URL and LIDARR_API_KEY to the compose file."})
                if how not in ("song", "album"):
                    return self.send(400, {"error": "Pick songs or albums."})
                which = b.get("indexes")
                which = set(which) if isinstance(which, list) else {t["i"] for t in job["tracks"]}
                with LOCK:
                    start_downloads(job, how, which)
                return self.send(200, public(job))
            if method == "POST" and action == "/rematch":
                nav = Navidrome(creds)
                with LOCK:
                    for t in job["tracks"]:
                        if t["status"] in ("missing", "failed"):
                            s = find_in_library(nav, t)
                            if s:
                                t.update(status="found", songId=s["id"], match=f'{s.get("artist", "")} - {s.get("title", "")}')
                    rebuild_playlist(job)
                    touch(job)
                save_jobs()
                return self.send(200, public(job))
        return self.send(404, {"error": "Not found"})

    def handle_any(self, method):
        try:
            self.route(method)
        except Exception as e:
            log("request error:", repr(e))
            try:
                self.send(500, {"error": str(e) or "Something went wrong"})
            except Exception:
                pass

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_DELETE(self):
        self.handle_any("DELETE")


def main():
    load_jobs()
    threading.Thread(target=worker, daemon=True).start()
    threading.Thread(target=watch_self, daemon=True).start()
    log(f"Needle helper {VERSION} on port {PORT}. Navidrome: {NAVIDROME}. "
        f"Soulseek: {'on' if SLSKD and SLSKD_KEY else 'off'}. Lidarr: {'on' if LIDARR and LIDARR_KEY else 'off'}.")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
