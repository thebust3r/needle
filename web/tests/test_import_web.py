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
spawn([sys.executable, "-u", os.path.join(SITE, "helper", "helper.py")], dict(NAVIDROME_URL=base, SPOTIFY_URL=base, MUSICBRAINZ_URL=base,
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
