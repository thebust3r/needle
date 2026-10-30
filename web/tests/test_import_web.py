"""Browser test of the Import screen with the real helper and fake Spotify/Navidrome/slskd/Lidarr.
Run: python3 test_import_web.py  (starts everything itself)"""
import asyncio, os, shutil, subprocess, sys, tempfile, time
from urllib.request import urlopen
from playwright.async_api import async_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.join(HERE, "..", "site")
SHOTS = os.environ.get("SHOTS", os.path.join(HERE, "shots"))
os.makedirs(SHOTS, exist_ok=True)
RESULTS = []
def check(name, cond, detail=""):
    RESULTS.append(bool(cond)); print(("PASS " if cond else "FAIL ") + name + (f"   [{detail}]" if detail and not cond else ""), flush=True)

tmp = tempfile.mkdtemp()
music, downloads, data = (os.path.join(tmp, d) for d in ("music", "downloads", "data"))
for d in (music, downloads, data): os.makedirs(d)
FS, HP, WEB, WEB2 = 18881, 18882, 8797, 8798
procs = []
def spawn(args, env=None):
    p = subprocess.Popen(args, env=dict(os.environ, **(env or {})), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); procs.append(p); return p
base = f"http://127.0.0.1:{FS}"
spawn([sys.executable, os.path.join(HERE, "fake_services.py"), str(FS), music, downloads])
spawn([sys.executable, "-u", os.path.join(SITE, "helper", "helper.py")], dict(NAVIDROME_URL=base, SPOTIFY_URL=base, MUSICBRAINZ_URL=base, DEEZER_URL=base + "/deezer",
      SLSKD_URL=base + "/slskd", SLSKD_API_KEY="slsk-key", LIDARR_URL=base + "/lidarr", LIDARR_API_KEY="lid-key", MUSIC_DIR=music,
      DOWNLOADS_DIR=downloads, DATA_DIR=data, PORT=str(HP), NEEDLE_FAST="1"))
spawn([sys.executable, os.path.join(HERE, "fake_server.py"), SITE], dict(PORT=str(WEB), HELPER_URL=f"http://127.0.0.1:{HP}", REST_FORWARD=base))
spawn([sys.executable, os.path.join(HERE, "fake_server.py"), SITE], dict(PORT=str(WEB2)))   # no helper running
for _ in range(80):
    try: [urlopen(u) for u in (base + "/_state", f"http://127.0.0.1:{HP}/helper/ping", f"http://127.0.0.1:{WEB}/", f"http://127.0.0.1:{WEB2}/")]; break
    except Exception: time.sleep(0.15)


async def page(browser, port):
    ctx = await browser.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=2, is_mobile=True, has_touch=True)
    await ctx.add_init_script("localStorage.setItem('needle.cfg', JSON.stringify({user:'mason',pass:'secret'}));")
    await ctx.grant_permissions(["clipboard-read", "clipboard-write"])
    pg = await ctx.new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" and "favicon" not in m.text and "404" not in m.text else None)
    return ctx, pg, errs


async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        ctx, pg, errs = await page(browser, WEB)
        W = f"http://127.0.0.1:{WEB}/"

        await pg.goto(W + "#/library")
        await pg.wait_for_selector("a.nav-row[href='#/import']")
        check("Library has 'Import a Spotify Playlist'", await pg.is_visible("a.nav-row[href='#/import']"))
        await pg.goto(W + "#/playlists")
        await pg.wait_for_selector(".pill[href='#/import']")
        check("Playlists screen has an Import button", True)

        await pg.goto(W + "#/import")
        await pg.wait_for_selector("#imp-src")
        await pg.wait_for_selector("#imp-list .empty, #imp-list .row")
        check("empty state explains how to copy a link", "Copy link" in await pg.inner_text("#imp-list"))
        await pg.click("#imp-go")
        check("asks for a link when empty", "Paste" in await pg.inner_text("#imp-err"))
        await pg.evaluate("navigator.clipboard.writeText('https://open.spotify.com/playlist/testmix0000000000000001?si=1')")
        await pg.click("#imp-paste")
        await pg.wait_for_timeout(300)
        check("Paste button fills the box", "testmix" in await pg.input_value("#imp-src"))
        await pg.screenshot(path=os.path.join(SHOTS, "import-1-paste.png"))
        await pg.click("#imp-go")
        await pg.wait_for_function("location.hash.startsWith('#/import/')")
        await pg.wait_for_function("document.querySelector('#imp-sum') && /8 of 12/.test(document.querySelector('#imp-sum').textContent)", timeout=15000)
        check("shows 8 of 12 found", True)
        check("title is the Spotify playlist name", (await pg.inner_text("#imp h1")) == "Road Trip Mix")
        card = await pg.inner_text(".imp-card")
        check("offers both download choices", "4 songs aren't in your library" in card and "Just the Songs" in card and "Whole Albums" in card, card)
        rows = await pg.eval_on_selector_all(".imp-row", "rs => rs.map(r => [r.className, r.innerText])")
        check("lists every song in order", len(rows) == 12 and rows[0][1].startswith("1"), len(rows))
        check("missing ones marked", sum("st-missing" in r[0] for r in rows) == 4)
        await pg.screenshot(path=os.path.join(SHOTS, "import-2-matched.png"), full_page=True)
        await pg.click("#imp-filter")
        n = await pg.eval_on_selector_all(".imp-row", "rs => rs.length")
        check("'Missing only' filter", n == 4, n)
        await pg.click("#imp-filter")

        await pg.click("[data-get='song']")
        await pg.wait_for_selector(".imp-row.st-searching, .imp-row.st-queued, .imp-row.st-downloading", timeout=5000)
        check("progress shows while downloading", True)
        await pg.wait_for_timeout(600)
        await pg.screenshot(path=os.path.join(SHOTS, "import-3-downloading.png"), full_page=True)
        await pg.wait_for_function("/10 of 12/.test(document.querySelector('#imp-sum')?.textContent || '') && !/on the way/.test(document.querySelector('#imp-sum').textContent)", timeout=60000)
        summ = await pg.inner_text("#imp-sum")
        check("ends with 10 of 12 and 2 not found", "10 of 12" in summ and "2 not found" in summ, summ)
        rows = await pg.eval_on_selector_all(".imp-row", "rs => rs.map(r => [r.className, r.innerText])")
        added = [r[1] for r in rows if "Added" in r[1]]
        check("downloaded songs marked Added", len(added) == 2, added)
        failed = [r[1] for r in rows if "st-failed" in r[0]]
        check("failed ones say why", len(failed) == 2 and all("·" in f for f in failed), failed)
        await pg.screenshot(path=os.path.join(SHOTS, "import-4-done.png"), full_page=True)

        await pg.click("[data-retry]")
        await pg.wait_for_selector("#menu:not([hidden]) [data-a='album']")
        check("retry offers song or album", True)
        await pg.click("#menu [data-a='album']")
        await pg.wait_for_timeout(300)

        await pg.click("a.pill[href^='#/playlist/']")
        await pg.wait_for_selector(".album-head h1")
        n = await pg.eval_on_selector_all(".row[data-index]", "rs => rs.length")
        check("playlist opens with the 10 songs in order", n == 10, n)
        first = await pg.inner_text(".row[data-index='0'] .meta b")
        check("first song is first", first == "Stressed Out", first)

        await pg.goto(W + "#/import")
        await pg.wait_for_selector("#imp-list .row")
        txt = await pg.inner_text("#imp-list")
        check("recent imports list it", "Road Trip Mix" in txt and "of 12" in txt, txt)
        await pg.screenshot(path=os.path.join(SHOTS, "import-5-recent.png"))

        await pg.fill("#imp-src", "https://open.spotify.com/playlist/doesnotexist000000000001")
        await pg.click("#imp-go")
        await pg.wait_for_function("/doesn't exist/.test(document.querySelector('#imp-sum')?.textContent || '')", timeout=10000)
        check("bad link explained on screen", True)
        check("no script errors", not errs, errs)

        # helper not running
        ctx2, pg2, errs2 = await page(browser, WEB2)
        await pg2.goto(f"http://127.0.0.1:{WEB2}/#/import")
        await pg2.wait_for_selector("#imp-list .empty")
        msg = await pg2.inner_text("#imp-list")
        check("explains when the helper isn't installed", "isn't running" in msg, msg)
        await pg2.fill("#imp-src", "Nirvana - Smells Like Teen Spirit")
        await pg2.click("#imp-go")
        await pg2.wait_for_timeout(500)
        check("import button shows the same hint", "isn't running" in await pg2.inner_text("#imp-err"))

        # search and download
        await pg.goto(W + "#/search")
        await pg.wait_for_selector("[data-mode='get']")
        await pg.click("[data-mode='get']")
        check("Download mode shows Songs / Albums", await pg.is_visible(".get-kinds"))
        await pg.fill("#q", "gods plan drake")
        await pg.wait_for_selector("#results .get-row")
        txt = await pg.inner_text("#results")
        check("lists songs from the catalog", "God's Plan" in txt and "Scorpion" in txt, txt[:200])
        await pg.wait_for_timeout(300)
        await pg.screenshot(path=os.path.join(SHOTS, "get-1-songs.png"))
        row = pg.locator("#results .get-row", has_text="God's Plan")
        await row.locator("[data-get]").click()
        await pg.wait_for_selector("#results .get-row:has-text(\"God's Plan\") .get-btn.sent")
        check("download button turns into a check", True)
        await pg.wait_for_function("(document.querySelector('#dl-badge')||{}).textContent !== undefined")
        await pg.fill("#q", "stressed")
        await pg.wait_for_selector("#results .get-row .get-btn.have")
        check("songs you have show a check instead", "Stressed Out" in await pg.inner_text("#results"))
        await pg.click("[data-kind='album']")
        await pg.fill("#q", "hurry up")
        await pg.wait_for_selector("#results a.get-row")
        await pg.click("#results a.get-row")
        await pg.wait_for_selector("#get-all")
        check("album page lists its songs", "Wait" in await pg.inner_text("#get-list"))
        await pg.wait_for_timeout(300)
        await pg.screenshot(path=os.path.join(SHOTS, "get-2-album.png"))
        await pg.click("#get-all")
        await pg.wait_for_function("document.querySelector('#get-all').textContent.includes('On the way')")
        check("Download Album sends the missing songs", True)
        await pg.goto(W + "#/downloads")
        await pg.wait_for_selector("#dl-list .dl-row")
        await pg.wait_for_function("[...document.querySelectorAll('#dl-list .dl-row')].some(r => r.textContent.includes(\"God's Plan\") && r.classList.contains('found'))", timeout=30000)
        check("Downloads screen shows it finished", True)
        await pg.wait_for_function("document.querySelectorAll('#dl-list .dl-row').length >= 2 && !document.querySelector('#dl-list .spin')", timeout=40000)
        dl = await pg.inner_text("#dl-list")
        check("the whole album came in", "Wait" in dl and await pg.locator("#dl-list .dl-row.found", has_text="Wait").count() >= 1, dl[:300])
        await pg.wait_for_timeout(300)
        await pg.screenshot(path=os.path.join(SHOTS, "get-3-downloads.png"))
        await pg.goto(W + "#/library")
        await pg.wait_for_selector("a.nav-row[href='#/downloads']")
        check("Library links to Downloads", True)

        # a library album you only have part of: the whole tracklist, missing songs grayed out
        import hashlib as _h
        aid = "alb-" + _h.md5("Drake|Scorpion".encode()).hexdigest()[:8]
        await pg.goto(W + f"#/album/{aid}")
        await pg.wait_for_selector("#album-list .row.missing", timeout=15000)
        txt = await pg.inner_text("#album-list")
        check("album shows every song, in order", txt.index("Nonstop") < txt.index("God's Plan") < txt.index("In My Feelings"), txt[:300])
        check("songs you don't have are grayed out", await pg.locator("#album-list .row.missing").count() == 2)
        check("the song you have still plays", await pg.locator("#album-list .row[data-index='0']", has_text="God's Plan").count() == 1)
        check("offers to download the missing songs", "2 Missing Songs" in await pg.inner_text("#get-missing"))
        await pg.wait_for_timeout(300)
        await pg.screenshot(path=os.path.join(SHOTS, "get-4-library-album.png"))
        await pg.click("#get-missing")
        await pg.wait_for_function("document.querySelector('#get-missing').textContent.includes('On the way')")
        check("Download Missing sends it off as one album", True)
        await pg.click("#album-list .row[data-index='0'] .more")
        await pg.click("#menu [data-act='delete']")
        await pg.wait_for_selector("#menu [data-del='yes']")
        await pg.click("#menu [data-del='yes']")
        await pg.wait_for_function("document.querySelector('#toast') && document.querySelector('#toast').textContent.startsWith('Deleted')", timeout=15000)
        check("delete a song from the library: its file is moved out of the music folder",
              not any(f.startswith("05 - God") for _, _, fs in os.walk(os.path.join(music, "Needle Downloads", "Drake")) for f in fs))
        check("...and its row goes away", await pg.locator("#album-list .row", has_text="God's Plan").count() == 0)
        check("album page has Delete Album", await pg.locator("#del-album").count() == 1)

        # wide screen
        await pg.set_viewport_size({"width": 1280, "height": 900})
        await pg.goto(W + "#/import")
        await pg.wait_for_selector("#imp-list .row")
        await pg.click("#imp-list .row")
        await pg.wait_for_selector("#imp-sum")
        await pg.wait_for_timeout(400)
        await pg.screenshot(path=os.path.join(SHOTS, "import-6-desktop.png"))
        await browser.close()

try:
    asyncio.run(main())
finally:
    for p in procs: p.kill()
    shutil.rmtree(tmp, ignore_errors=True)
print(f"\n{sum(RESULTS)} passed, {RESULTS.count(False)} failed")
sys.exit(0 if all(RESULTS) else 1)
