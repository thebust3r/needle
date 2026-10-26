"""Tests for the playlist import helper against fake Spotify / Navidrome / slskd / Lidarr / MusicBrainz.
Run: python3 test_helper.py"""
import hashlib, json, os, shutil, signal, subprocess, sys, tempfile, time
from urllib.request import Request, urlopen
from urllib.error import HTTPError

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "site", "helper", "helper.py")
sys.path.insert(0, os.path.dirname(HELPER))
import helper as H  # noqa: E402

passed, failed = 0, []
def check(name, cond, detail=""):
    global passed
    if cond: passed += 1; print("  ok  ", name)
    else: failed.append(name); print("  FAIL", name, detail)

# ---------------------------------------------------------------- unit checks
print("Matching rules")
check("remaster suffix dropped", H.clean_title("Hey Jude - Remastered 2015") == "hey jude")
check("feat dropped", H.clean_title("SICKO MODE (feat. Drake)") == "sicko mode")
check("live kept", H.clean_title("Ride - Live") == "ride live")
check("remix in brackets kept", H.clean_title("Song (Club Remix)") == "song club remix")
check("accents folded", H.norm("Señorita") == "senorita")
check("radio edit dropped", H.clean_title("Wake Me Up - Radio Edit") == "wake me up")
s = {"title": "Ride", "artist": "Twenty One Pilots", "duration": 214}
check("live doesn't match studio", H.song_score({"title": "Ride - Live", "artists": ["Twenty One Pilots"], "duration": 260}, s) < 0.86)
check("wrong artist rejected", H.song_score({"title": "Ride", "artists": ["Lana Del Rey"], "duration": 0}, s) == 0)
check("duet matches", H.song_score({"title": "Señorita", "artists": ["Shawn Mendes", "Camila Cabello"], "duration": 191},
                                   {"title": "Señorita", "artist": "Shawn Mendes & Camila Cabello", "duration": 190}) > 0.95)
check("'The' optional", H.artist_ok(["Beatles"], {"artist": "The Beatles"}))
check("track number on untagged file", H.title_score("Midnight City", "04 - Midnight City") > 0.95)
check("numbers in real titles kept", H.title_score("7 rings", "7 rings") == 1 and H.title_score("7 rings", "rings") < 0.86 and H.title_score("22", "22") == 1)
check("spotify link", H.spotify_link("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc") == ("playlist", "37i9dQZF1DXcBWIGoYBM5M"))
check("intl link", H.spotify_link("https://open.spotify.com/intl-es/album/1A2GTWGtFfWp7KSQTwWOyo") == ("album", "1A2GTWGtFfWp7KSQTwWOyo"))
check("uri", H.spotify_link("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M") == ("playlist", "37i9dQZF1DXcBWIGoYBM5M"))
txt = H.read_text("1. Three 6 Mafia - Tear da Club Up\nHey Jude by The Beatles\n- Nirvana – Smells Like Teen Spirit\nLovely Day\n")
check("text lines", [(t["title"], t["artists"][:1]) for t in txt] == [("Tear da Club Up", ["Three 6 Mafia"]), ("Hey Jude", ["The Beatles"]),
                                                                       ("Smells Like Teen Spirit", ["Nirvana"]), ("Lovely Day", [])], txt)
csvt = H.read_text('Track URI,Track Name,Artist Name(s),Album Name,Duration (ms)\nspotify:track:x,"Señorita","Shawn Mendes,Camila Cabello",Album,190000\n')
check("exportify csv", csvt[0]["title"] == "Señorita" and "Camila Cabello" in csvt[0]["artists"] and csvt[0]["duration"] == 190, csvt)
check("primary artist from a joined list", H.primary_artist({"artists": ["Shawn Mendes, Camila Cabello", "Shawn Mendes", "Camila Cabello"]}) == "Shawn Mendes")
picks = H.pick_files({"title": "Midnight City", "artists": ["M83"], "duration": 244}, [
    {"username": "a", "hasFreeUploadSlot": True, "files": [{"filename": "x\\M83\\Midnight City (Remix).mp3", "length": 244},
                                                         {"filename": "x\\M83\\Midnight City.mp3", "bitRate": 320, "length": 244},
                                                         {"filename": "x\\Other\\Midnight City.mp3", "bitRate": 320, "length": 244}]}])
check("file picker skips remix, needs artist", len(picks) == 1 and picks[0]["filename"].endswith("M83\\Midnight City.mp3"), picks)

# ---------------------------------------------------------------- live run
tmp = tempfile.mkdtemp()
music, downloads, data = (os.path.join(tmp, d) for d in ("music", "downloads", "data"))
for d in (music, downloads, data): os.makedirs(d)
FP, HP = 18871, 18872
fake = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_services.py"), str(FP), music, downloads])
base = f"http://127.0.0.1:{FP}"
env = dict(os.environ, NAVIDROME_URL=base, SPOTIFY_URL=base, MUSICBRAINZ_URL=base, SLSKD_URL=base + "/slskd", SLSKD_API_KEY="slsk-key",
           LIDARR_URL=base + "/lidarr", LIDARR_API_KEY="lid-key", MUSIC_DIR=music, DOWNLOADS_DIR=downloads, DATA_DIR=data,
           PORT=str(HP), NEEDLE_FAST="1")
run_dir = os.path.join(tmp, "app"); os.makedirs(run_dir)
helper_copy = os.path.join(run_dir, "helper.py"); shutil.copy(HELPER, helper_copy)
def start_helper():
    return subprocess.Popen([sys.executable, "-u", helper_copy], env=env, stdout=open(os.path.join(tmp, "helper.log"), "a"), stderr=subprocess.STDOUT)
proc = start_helper()

def auth(user="mason", pw="secret"):
    salt = "abc123"; return f"u={user}&t={hashlib.md5((pw + salt).encode()).hexdigest()}&s={salt}"
def call(path, body=None, method=None, a=None):
    url = f"http://127.0.0.1:{HP}/helper{path}{'&' if '?' in path else '?'}{a or auth()}"
    req = Request(url, data=json.dumps(body).encode() if body is not None else None, method=method or ("POST" if body is not None else "GET"),
                  headers={"Content-Type": "application/json"})
    try:
        with urlopen(req, timeout=10) as r: return r.status, json.loads(r.read())
    except HTTPError as e: return e.code, json.loads(e.read() or b"{}")
def state(): return json.loads(urlopen(base + "/_state").read())
def wait_job(jid, cond, secs=30):
    end = time.time() + secs
    while time.time() < end:
        _, j = call(f"/jobs/{jid}")
        if cond(j): return j
        time.sleep(0.2)
    return j

for _ in range(50):
    try: urlopen(f"http://127.0.0.1:{HP}/helper/ping"); urlopen(base + "/_state"); break
    except Exception: time.sleep(0.1)

try:
    print("Security")
    code, _ = call("/status", a="u=mason&t=bad&s=x")
    check("wrong password rejected", code == 401)
    code, _ = call("/jobs", a="x=1")
    check("no login rejected", code == 401)
    code, st = call("/status")
    check("status shows both downloaders", code == 200 and st["soulseek"] and st["lidarr"], st)

    print("Import a Spotify playlist")
    code, j = call("/import", {"source": "https://open.spotify.com/playlist/testmix0000000000000001?si=xyz"})
    check("import accepted", code == 200 and j["id"], j)
    j = wait_job(j["id"], lambda j: j["state"] in ("ready", "error"))
    check("import finished", j["state"] == "ready", j.get("error"))
    check("name from Spotify", j["name"] == "Road Trip Mix")
    found = [t["title"] for t in j["tracks"] if t["status"] == "found"]
    missing = [t["title"] for t in j["tracks"] if t["status"] == "missing"]
    check("8 of 12 found", len(found) == 8, found)
    check("variants handled (remaster, feat, accent, duet)", {"Hey Jude - Remastered 2015", "SICKO MODE (feat. Drake)", "Señorita"} <= set(found))
    check("live version counted as missing", "Ride - Live" in missing)
    pl = state()["playlists"][j["playlistId"]]
    want_order = [t["songId"] for t in j["tracks"] if t.get("songId")]
    check("playlist created in Spotify order", pl["songs"] == want_order and pl["name"] == "Road Trip Mix", pl)
    jid = j["id"]
    code, lst = call("/jobs")
    check("listed in recent imports", any(x["id"] == jid and x["found"] == 8 for x in lst["jobs"]))
    code, _ = call(f"/jobs/{jid}", a=auth("someoneelse", "secret"))
    check("other accounts can't see it", code in (401, 404))

    print("Download missing songs through Soulseek")
    idx = [t["i"] for t in j["tracks"] if t["title"] in ("Midnight City", "Weird Fishes", "Obscure Song")]
    code, j = call(f"/jobs/{jid}/download", {"method": "song", "indexes": idx})
    check("download started", code == 200 and all(t["status"] in ("queued", "searching") for t in j["tracks"] if t["i"] in idx), j)
    j = wait_job(jid, lambda j: not j["active"], 60)
    by = {t["title"]: t for t in j["tracks"]}
    check("Midnight City downloaded and added", by["Midnight City"]["status"] == "found", by["Midnight City"])
    check("picked the fast FLAC, not the remix", "Hurry Up We're Dreaming" not in by["Midnight City"].get("file", "x") and by["Midnight City"].get("file", "").endswith("04 - Midnight City.flac"), by["Midnight City"])
    check("Weird Fishes fell back to the second user", by["Weird Fishes"]["status"] == "found", by["Weird Fishes"])
    check("remix-only song reported, not grabbed", by["Obscure Song"]["status"] == "failed" and "Soulseek" in by["Obscure Song"]["note"], by["Obscure Song"])
    check("files moved into Music/Needle Downloads/<artist>", os.path.exists(os.path.join(music, "Needle Downloads", "M83", "04 - Midnight City.flac"))
          and os.path.exists(os.path.join(music, "Needle Downloads", "Radiohead", "04 - Weird Fishes_Arpeggi.mp3")))
    check("downloads folder cleaned up", not any(f for _, _, fs in os.walk(downloads) for f in fs))
    pl = state()["playlists"][j["playlistId"]]
    order = [t["songId"] for t in j["tracks"] if t.get("songId")]
    check("new songs slotted into the right spots", pl["songs"] == order and len(order) == 10, (pl["songs"], order))
    pos = [t["title"] for t in j["tracks"] if t.get("songId")]
    check("order kept around them", pos.index("Midnight City") == pos.index("Ultralight Beam") + 1)
    sl = state()["slsk"]
    check("searched with artist + title", "m83 midnight city" in sl, sl)
    check("retried the remix-only song by title", "obscure song" in sl, sl)

    print("Whole album through Lidarr")
    code, j2 = call("/import", {"source": "https://open.spotify.com/playlist/albumrequest00000000001", "name": "My Album Test"})
    j2 = wait_job(j2["id"], lambda j: j["state"] != "matching" and j["state"] != "reading")
    check("custom name used", j2["name"] == "My Album Test")
    hol = [t["i"] for t in j2["tracks"] if t["title"] == "Holocene"]
    code, j2 = call(f"/jobs/{j2['id']}/download", {"method": "album", "indexes": hol})
    j2 = wait_job(j2["id"], lambda j: not j["active"], 30)
    t = [t for t in j2["tracks"] if t["title"] == "Holocene"][0]
    check("album requested and song added", t["status"] == "found", t)
    adds = [x for x in state()["lidarr"] if x[0] == "POST" and x[1] == "album"]
    look = [x for x in state()["lidarr"] if x[1] == "album/lookup"]
    check("picked the studio album, not the single or live one", look and look[0][2]["term"] == "lidarr:rg-album", look)
    check("added to Lidarr once", len(adds) == 1)
    check("playlist has both songs", len(state()["playlists"][j2["playlistId"]]["songs"]) == 2)

    print("Pasted list and limits")
    code, j3 = call("/import", {"source": "Three 6 Mafia - Tear da Club Up\nNirvana - Smells Like Teen Spirit\nSomebody - Not Here"})
    j3 = wait_job(j3["id"], lambda j: j["state"] in ("ready", "error"))
    check("pasted list: 2 of 3", j3["found"] == 2 and j3["name"].startswith("Imported"), j3)
    code, j4 = call("/import", {"source": "https://open.spotify.com/playlist/big00000000000000000001"})
    j4 = wait_job(j4["id"], lambda j: j["state"] in ("ready", "error"))
    check("100-song cap explained", "first 100" in (j4.get("note") or ""), j4.get("note"))
    code, j5 = call("/import", {"source": "https://open.spotify.com/playlist/doesnotexist000000000001"})
    j5 = wait_job(j5["id"], lambda j: j["state"] in ("ready", "error"))
    check("bad link explained", j5["state"] == "error" and "doesn't exist" in j5["error"], j5)
    code, j6 = call("/import", {"source": "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"})
    j6 = wait_job(j6["id"], lambda j: j["state"] in ("ready", "error"))
    check("single-song link explained", j6["state"] == "error" and "one song" in j6["error"])
    code, _ = call("/import", {"source": ""})
    check("empty rejected", code == 400)

    print("Restarts and updates")
    proc.send_signal(signal.SIGTERM); proc.wait(5)
    proc = start_helper(); time.sleep(1.0)
    code, j = call(f"/jobs/{jid}")
    check("imports survive a restart", code == 200 and j["found"] == 10, (code, j.get("found")))
    time.sleep(1.2)
    os.utime(helper_copy, (time.time() + 5, time.time() + 5))
    try: rc = proc.wait(15)
    except subprocess.TimeoutExpired: rc = None
    check("restarts itself when updated (exit 3)", rc == 3, rc)
    proc = start_helper(); time.sleep(0.8)
    code, _ = call(f"/jobs/{jid}/rematch", {})
    check("rematch works", code == 200)
    code, _ = call(f"/jobs/{jid}", method="DELETE")
    code2, _ = call(f"/jobs/{jid}")
    check("delete removes from list", code == 200 and code2 == 404)
finally:
    proc.kill(); fake.kill()
    log = open(os.path.join(tmp, "helper.log")).read()
    if failed: print(log[-3000:])
    shutil.rmtree(tmp, ignore_errors=True)

print(f"\n{passed} passed, {len(failed)} failed")
sys.exit(1 if failed else 0)
