"""Browser tests for the queue (Play Next / Add to Queue order), swiping song rows, favorites and playlists.
Starts its own fake server."""
import asyncio, json, os, subprocess, sys, time
from urllib.request import urlopen
from playwright.async_api import async_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.join(HERE, "..", "site")
SHOTS = os.environ.get("SHOTS", os.path.join(HERE, "shots"))
os.makedirs(SHOTS, exist_ok=True)
PORT = 8801
BASE = f"http://127.0.0.1:{PORT}/"
RESULTS = []
def check(name, cond, detail=""):
    RESULTS.append(bool(cond)); print(("PASS " if cond else "FAIL ") + name + (f"   [{detail}]" if detail else ""), flush=True)

srv = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_server.py"), SITE], env=dict(os.environ, PORT=str(PORT)),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(60):
    try: urlopen(BASE); break
    except Exception: time.sleep(0.1)

created = lambda: json.loads(urlopen(BASE + "_created").read())


async def swipe(pg, sel, dx):
    await pg.evaluate("(s) => document.querySelector(s).scrollIntoView({block: 'center'})", sel)
    await pg.wait_for_timeout(100)
    box = await pg.locator(sel).bounding_box()
    x, y = box["x"] + box["width"] / 2, box["y"] + box["height"] / 2
    await pg.mouse.move(x, y); await pg.mouse.down()
    for k in range(1, 11):
        await pg.mouse.move(x + dx * k / 10, y + k * 0.3); await pg.wait_for_timeout(16)
    await pg.mouse.up()


async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"])
        ctx = await browser.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=2)
        await ctx.add_init_script("if (!sessionStorage.getItem('seeded')) { sessionStorage.setItem('seeded','1');"
                                  "localStorage.setItem('needle.cfg', JSON.stringify({user:'mason',pass:'pw'})); }")
        pg = await ctx.new_page()
        errs = []
        pg.on("pageerror", lambda e: errs.append(str(e)))

        print("\n== Queue order ==")
        await pg.goto(BASE + "#/album/al0")
        await pg.wait_for_selector("#view .row[data-index]")
        ids = await pg.evaluate("screenTracks.map(t => t.id)")
        await pg.click("#view .row[data-index='0']")
        await pg.wait_for_function("player.current && player.current.id === %s" % json.dumps(ids[0]))
        await pg.evaluate("closeNP()")
        a, b, c = [{"id": f"x{k}", "title": f"Extra {k}", "artist": "Q", "album": "Q", "duration": 30} for k in range(3)]
        await pg.evaluate("([a,b,c]) => { player.addToQueue([a]); player.playNext([b]); player.addToQueue([c]); }", [a, b, c])
        order = await pg.evaluate("player.queue.slice(player.i + 1, player.i + 5).map(t => t.id)")
        check("Play Next goes first, then songs you added, in order, then the rest of the album",
              order == ["x1", "x0", "x2", ids[1]], order)
        check("three songs counted as queued", await pg.evaluate("player.queuedCount()") == 3)
        await pg.evaluate("player.skip()")
        await pg.wait_for_function("player.current.id === 'x1'")
        await pg.evaluate("if (!$('#np').hidden) closeNP()")
        await pg.evaluate("player.addToQueue([{id:'x3', title:'Extra 3', artist:'Q', album:'Q', duration: 30}])")
        order = await pg.evaluate("player.queue.slice(player.i + 1, player.i + 4).map(t => t.id)")
        check("Add to Queue after playing a queued song still lands before the album", order == ["x0", "x2", "x3"], order)

        print("\n== Queue sheet ==")
        await pg.evaluate("$('#queue').hidden = false; renderQueue()")
        txt = await pg.inner_text("#queue")
        check("shows a Next in Queue section", "Next in Queue" in txt and "Then" in txt, txt[:200])
        await pg.click("#q-clear")
        check("Clear empties Next in Queue", await pg.evaluate("player.queuedCount()") == 0
              and await pg.evaluate("player.queue[player.i + 1].id") == ids[1])
        await pg.click("#q-done")

        print("\n== Shuffle keeps queued songs on top ==")
        await pg.evaluate("player.addToQueue([{id:'x5', title:'Extra 5', artist:'Q', album:'Q', duration: 30}])")
        await pg.evaluate("player.toggleShuffle()")
        check("after shuffling, your queued song is still next", await pg.evaluate("player.queue[player.i + 1].id") == "x5")
        await pg.evaluate("player.toggleShuffle()")
        check("after unshuffling, it's still next", await pg.evaluate("player.queue[player.i + 1].id") == "x5")

        print("\n== Swipe ==")
        n0 = await pg.evaluate("player.queuedCount()")
        await swipe(pg, "#view .row[data-index='3']", 160)
        await pg.wait_for_timeout(200)
        check("swipe right adds the song to the queue",
              await pg.evaluate("player.queuedCount()") == n0 + 1 and await pg.evaluate("player.queue[player.i + 1 + %d].id" % n0) == ids[3])
        check("swiping doesn't start playing the song", await pg.evaluate("player.current.id") != ids[3])
        t0 = await pg.inner_text("#toast")
        check("tells you it was added", "queue" in t0.lower(), t0)
        await swipe(pg, "#view .row[data-index='2']", -160)
        await pg.wait_for_timeout(300)
        check("swipe left favorites the song", await pg.evaluate("screenTracks[2].starred") is True
              and any(c.get("star") == [ids[2]] for c in created()))
        check("the row shows a heart", await pg.locator("#view .row[data-index='2'] svg.fav").count() == 1)
        await swipe(pg, "#view .row[data-index='2']", -160)
        await pg.wait_for_timeout(300)
        check("swipe left again un-favorites it", await pg.evaluate("screenTracks[2].starred") is False
              and any(c.get("unstar") == [ids[2]] for c in created()))
        await swipe(pg, "#view .row[data-index='4']", 30)
        await pg.wait_for_timeout(200)
        check("a short swipe does nothing", await pg.evaluate("player.queue.slice(player.i + 1).filter(t => t.queued && t.id === %s).length" % json.dumps(ids[4])) == 0)
        check("row springs back", await pg.evaluate("getComputedStyle(document.querySelector(\"#view .row[data-index='4']\")).getPropertyValue('--dx').trim()") in ("0px", ""))
        await pg.click("#view .row[data-index='5']")
        await pg.wait_for_function("player.current.id === %s" % json.dumps(ids[5]))
        check("a tap still plays the song", True)
        await pg.evaluate("if (!$('#np').hidden) closeNP()")

        print("\n== Add to Playlist ==")
        await pg.click("#view .row[data-index='1'] .more")
        await pg.click("#menu [data-act='playlist']")
        await pg.wait_for_selector("#menu [data-pl='pl1']")
        await pg.wait_for_timeout(500); await pg.screenshot(path=os.path.join(SHOTS, "add-to-playlist.png"))
        await pg.click("#menu [data-pl='pl1']")
        await pg.wait_for_timeout(300)
        check("adds the song to the playlist you pick", any(c.get("update") == "pl1" and c.get("songIdToAdd") == [ids[1]] for c in created()))
        await pg.click("#view .row[data-index='1'] .more")
        await pg.click("#menu [data-act='playlist']")
        await pg.fill("#pl-name", "Late Night")
        await pg.click("#pl-new button[type=submit]")
        await pg.wait_for_timeout(300)
        check("makes a new playlist with the song in it", any(c.get("name") == ["Late Night"] and c.get("songId") == [ids[1]] for c in created()))
        await pg.click("#view .row[data-index='1'] .more")
        await pg.click("#menu [data-act='star']")
        await pg.wait_for_timeout(200)
        check("menu can favorite too", await pg.evaluate("screenTracks[1].starred") is True)

        print("\n== Playlists screen ==")
        await pg.goto(BASE + "#/playlists")
        await pg.wait_for_selector("#pl-create")
        await pg.click("#pl-create")
        await pg.fill("#pl-name", "Empty One")
        await pg.click("#pl-new button[type=submit]")
        await pg.wait_for_function("location.hash === '#/playlist/pl9'")
        check("New Playlist makes one and opens it", any(c.get("name") == ["Empty One"] and "songId" not in c for c in created()))
        await pg.goto(BASE + "#/playlist/pl1")
        await pg.wait_for_selector("#view .row[data-index='2']")
        await pg.click("#view .row[data-index='2'] .more")
        await pg.click("#menu [data-act='unlist']")
        await pg.wait_for_timeout(300)
        check("Remove from This Playlist", any(c.get("update") == "pl1" and c.get("songIndexToRemove") == ["2"] for c in created()))

        check("no script errors", not errs, errs[:3])
        await browser.close()

try:
    asyncio.run(main())
finally:
    srv.kill()
print(f"\n{sum(RESULTS)} passed, {RESULTS.count(False)} failed")
sys.exit(0 if all(RESULTS) else 1)
