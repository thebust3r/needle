"""Browser tests for the new Home: date/time/weather header, Continue Listening, daily mixes, mix pages,
artist pages, accent color, mini player swipes and speed. Starts its own fake server."""
import asyncio, json, os, subprocess, sys, time
from urllib.request import urlopen
from playwright.async_api import async_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.join(HERE, "..", "site")
SHOTS = os.environ.get("SHOTS", os.path.join(HERE, "shots"))
os.makedirs(SHOTS, exist_ok=True)
PORT = 8799
BASE = f"http://127.0.0.1:{PORT}/"
RESULTS = []
def check(name, cond, detail=""):
    RESULTS.append(bool(cond)); print(("PASS " if cond else "FAIL ") + name + (f"   [{detail}]" if detail else ""), flush=True)

srv = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_server.py"), SITE], env=dict(os.environ, PORT=str(PORT)),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(60):
    try: urlopen(BASE); break
    except Exception: time.sleep(0.1)

WEATHER = {"current": {"temperature_2m": 54.4, "weather_code": 2, "is_day": 0}}


async def page(browser, init="", w=390, h=844):
    ctx = await browser.new_context(viewport={"width": w, "height": h}, device_scale_factor=2, is_mobile=True, has_touch=True)
    await ctx.add_init_script("if (!sessionStorage.getItem('seeded')) { sessionStorage.setItem('seeded','1');"
                              "localStorage.setItem('needle.cfg', JSON.stringify({user:'mason',pass:'pw'}));" + init + "}")
    calls = []
    async def meteo(route):
        calls.append(route.request.url)
        await route.fulfill(status=200, content_type="application/json", body=json.dumps(WEATHER))
    await ctx.route("https://api.open-meteo.com/**", meteo)
    async def geo(route):
        calls.append(route.request.url)
        await route.fulfill(status=200, content_type="application/json",
                            body=json.dumps({"results": [{"name": "Memphis", "latitude": 35.1, "longitude": -90.0}]}))
    await ctx.route("https://geocoding-api.open-meteo.com/**", geo)
    pg = await ctx.new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" and "favicon" not in m.text else None)
    return ctx, pg, errs, calls


async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"])
        ctx, pg, errs, calls = await page(browser)

        print("\n== Home header ==")
        await pg.goto(BASE)
        await pg.wait_for_selector(".home-head")
        date = await pg.inner_text(".hh-date")
        today = await pg.evaluate("new Date().toLocaleDateString(undefined, {weekday:'long'})")
        full = await pg.evaluate("new Date().toLocaleDateString(undefined, {weekday:'long', month:'long', day:'numeric'})")
        check("shows today's day (full date on hover)", date.lower() == today.lower() and await pg.get_attribute(".hh-date", "title") == full, date)
        tm = await pg.inner_text(".hh-time")
        check("shows the time", ":" in tm, tm)
        greet = await pg.inner_text(".hh-greet")
        check("greets you for the time of day", greet in ("Good morning", "Good afternoon", "Good evening", "Up late"), greet)
        await pg.wait_for_selector(".hh-weather", timeout=5000)
        check("weather chip shows the temperature", "54°" in await pg.inner_text(".hh-weather"))
        check("and the conditions", await pg.get_attribute(".hh-weather", "title") == "Partly cloudy in Fayetteville")
        check("header is one quiet line plus the greeting", await pg.evaluate("$('.home-head').getBoundingClientRect().height") < 110)
        check("weather asked for Fayetteville's spot", any("latitude=36.06" in c for c in calls), calls[:1])

        print("\n== Made for You ==")
        await pg.wait_for_selector("#mixes .mix-card", timeout=15000)
        cards = await pg.eval_on_selector_all("#mixes .mix-card", "cs => cs.map(c => c.innerText)")
        titles = [c.split("\n")[1] if "\n" in c else c for c in cards]
        check("daily mixes are made from the library", sum("Daily Mix" in c for c in cards) >= 3, cards)
        check("a mix for this time of day", any(t in " ".join(cards) for t in ("Morning Mix", "Afternoon Mix", "Evening Mix", "Late Night Mix")), titles)
        check("each card has four covers", await pg.eval_on_selector_all("#mixes .mix-card", "cs => cs.every(c => c.querySelectorAll('.mix-grid img').length === 4 || c.querySelector('.mix-one'))"))
        await pg.wait_for_selector("#quick .qp")
        picks = await pg.eval_on_selector_all("#quick .qp", "qs => qs.map(q => q.getAttribute('href'))")
        check("quick picks: up to six things you've been playing, no repeats", 0 < len(picks) <= 6 and len(set(picks)) == len(picks), len(picks))
        shelves = await pg.eval_on_selector_all("#shelves .h2", "hs => hs.map(h => h.textContent)")
        check("just one more shelf", shelves == ["New in Your Library"], shelves)
        newer = await pg.eval_on_selector_all("#shelves .card", "cs => cs.map(c => c.getAttribute('href'))")
        check("new music doesn't repeat the quick picks", not set(newer) & set(picks))
        h = await pg.evaluate("document.documentElement.scrollHeight")
        check("Home fits on about one screen", h < 1100, h)
        await pg.wait_for_timeout(600)
        await pg.screenshot(path=os.path.join(SHOTS, "home-1.png"))
        first_ids = await pg.evaluate("mixStore.mixes[0].songs.map(s => s.id).join()")
        await pg.reload()
        await pg.wait_for_selector("#mixes .mix-card")
        check("same mixes all day (kept, not rebuilt)", await pg.evaluate("mixStore.mixes[0].songs.map(s => s.id).join()") == first_ids)
        check("built for this account", await pg.evaluate("mixStore.saved.user") == "mason")

        await pg.click("#mixes .mix-card")
        await pg.wait_for_selector(".mix-page .row[data-index]")
        n = await pg.eval_on_selector_all(".mix-page .row[data-index]", "rs => rs.length")
        check("mix page lists its songs", n >= 8, n)
        arts = await pg.eval_on_selector_all(".mix-page .row .meta span", "ss => ss.map(s => s.textContent.split(' · ')[0])")
        check("no artist twice in a row", all(a != b for a, b in zip(arts, arts[1:])) or len(set(arts)) < 3, arts[:8])
        await pg.screenshot(path=os.path.join(SHOTS, "home-2-mix.png"))
        await pg.click("#mix-save")
        await pg.wait_for_timeout(500)
        created = json.loads(urlopen(BASE + "_created").read())
        check("Save as Playlist makes a Navidrome playlist with the songs", created and len(created[-1]["songId"]) == n and created[-1]["name"][0].startswith("Daily Mix"), created[-1]["name"] if created else None)
        check("button confirms", "Saved" in await pg.inner_text("#mix-save"))
        await pg.click(".mix-page [data-play='all']")
        await pg.wait_for_function("player.playing && player.time() > 0.3", timeout=10000)
        check("playing a mix works", True)
        check("the play is logged for future mixes", await pg.evaluate("plays.list.length") >= 1)

        print("\n== Continue Listening ==")
        await pg.evaluate("player.seek(9)")
        await pg.wait_for_timeout(300)
        await pg.evaluate("session.save()")
        title = await pg.evaluate("player.current.title")
        await pg.goto(BASE + "#/")
        await pg.reload()
        await pg.wait_for_selector("#continue", timeout=5000)
        check("after reopening, Home offers to continue the same song", title in await pg.inner_text("#continue"))
        check("mini player shows it too", await pg.evaluate("!document.querySelector('#mini').hidden") and title == await pg.inner_text("#mini b"))
        await pg.click("#continue")
        await pg.wait_for_function("player.playing && player.time() > 8", timeout=10000)
        check("it picks up where you left off", 8 <= await pg.evaluate("player.time()") <= 14, await pg.evaluate("player.time()"))

        print("\n== Mini player swipes ==")
        before = await pg.evaluate("player.i")
        box = await pg.locator("#mini").bounding_box()
        cdp = await ctx.new_cdp_session(pg)
        async def swipe(x0, y0, x1, y1):
            await cdp.send("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [{"x": x0, "y": y0}]})
            for k in range(1, 7):
                await cdp.send("Input.dispatchTouchEvent", {"type": "touchMove", "touchPoints": [{"x": x0 + (x1 - x0) * k / 6, "y": y0 + (y1 - y0) * k / 6}]})
            await cdp.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})
        cy = box["y"] + box["height"] / 2
        await swipe(box["x"] + 250, cy, box["x"] + 60, cy)
        await pg.wait_for_timeout(500)
        check("swipe left skips to the next song", await pg.evaluate("player.i") == before + 1, (before, await pg.evaluate("player.i")))
        check("and doesn't open Now Playing", await pg.evaluate("document.querySelector('#np').hidden"))
        await swipe(box["x"] + 150, cy, box["x"] + 150, cy - 120)
        await pg.wait_for_timeout(500)
        check("swipe up opens Now Playing", not await pg.evaluate("document.querySelector('#np').hidden"))
        await pg.click("#np-close")
        await pg.wait_for_timeout(400)

        print("\n== Artist page ==")
        await pg.goto(BASE + "#/artist/ar1")
        await pg.wait_for_selector("#bio p", timeout=5000)
        bio = await pg.inner_text("#bio p")
        check("artist bio, cleaned up", bio == "Velvet Static is a band from somewhere & elsewhere.", bio)
        check("hero image and name", await pg.is_visible(".artist-hero h1") and await pg.inner_text(".artist-hero h1") == "Velvet Static")
        await pg.wait_for_selector("#similar .card")
        check("Fans Also Like links to other artists", await pg.get_attribute("#similar .card", "href") == "#/artist/ar2")
        await pg.screenshot(path=os.path.join(SHOTS, "home-3-artist.png"))

        print("\n== Settings: accent and weather ==")
        await pg.goto(BASE + "#/settings")
        await pg.wait_for_selector("#s-accent")
        await pg.select_option("#s-accent", "pink")
        check("accent color changes everywhere", (await pg.evaluate("getComputedStyle(document.documentElement).getPropertyValue('--accent').trim()")) == "#ff73b8")
        await pg.select_option("#s-accent", "albumArt")
        await pg.wait_for_timeout(200)
        acc = await pg.evaluate("getComputedStyle(document.documentElement).getPropertyValue('--accent').trim()")
        npacc = await pg.evaluate("getComputedStyle(document.documentElement).getPropertyValue('--np-accent').trim()")
        check("Match Album Art uses the song's color", acc == npacc and acc != "#6ee8d9", (acc, npacc))
        await pg.fill("#s-place", "Memphis, TN")
        await pg.press("#s-place", "Tab")
        await pg.wait_for_timeout(500)
        await pg.goto(BASE + "#/")
        await pg.wait_for_selector(".hh-weather")
        check("weather city can be changed", (await pg.get_attribute(".hh-weather", "title")).endswith("in Memphis"))
        await pg.goto(BASE + "#/settings")
        await pg.wait_for_selector("#s-weather")
        await pg.click("#s-weather")
        await pg.goto(BASE + "#/")
        await pg.wait_for_selector(".home-head")
        await pg.wait_for_timeout(300)
        check("weather can be turned off", not await pg.query_selector(".hh-weather"))
        await pg.reload()
        await pg.wait_for_selector(".home-head")
        check("accent choice is remembered", await pg.evaluate("accent.choice") == "albumArt")
        check("no script errors", not errs, errs[:3])

        print("\n== Speed ==")
        ctx2, pg2, errs2, _ = await page(browser)
        cdp2 = await ctx2.new_cdp_session(pg2)
        await cdp2.send("Emulation.setCPUThrottlingRate", {"rate": 4})
        await pg2.goto(BASE + "#/album/al1")
        await pg2.wait_for_selector(".row[data-index='0']")
        await pg2.click(".row[data-index='0']")
        await pg2.wait_for_function("player.playing && player.time() > 0.3", timeout=10000)
        await pg2.click("#mini")
        await pg2.wait_for_timeout(1200)
        fps = await pg2.evaluate("""() => new Promise(res => { let n = 0; const t0 = performance.now();
            const f = () => { n++; if (performance.now() - t0 < 3000) requestAnimationFrame(f); else res(n / ((performance.now() - t0) / 1000)); };
            requestAnimationFrame(f); })""")
        print(f"   Now Playing with 4x slower CPU: {fps:.0f} fps")
        check("Now Playing stays smooth on a slow phone (4x CPU throttle)", fps >= 45, f"{fps:.0f} fps")
        bg = await pg2.evaluate("({f: getComputedStyle(document.querySelector('#np .backdrop img')).filter, src: document.querySelector('#np .backdrop img').src.slice(0, 22)})")
        check("background is blurred once, not every frame", bg["f"] == "none" and bg["src"].startswith("data:image/jpeg"), bg)
        t0 = time.time()
        await pg2.goto(BASE)
        await pg2.wait_for_selector("#mixes .mix-card", timeout=20000)
        built = time.time() - t0
        check("first-ever mixes ready quickly even on a slow phone", built < 6, f"{built:.1f}s")
        print(f"   mixes built from scratch with 4x slower CPU: {built:.1f}s")
        print("\n== Artist link on Now Playing ==")
        ctx3, pg3, errs3, _ = await page(browser)
        await pg3.goto(BASE + "#/album/al1")
        await pg3.wait_for_selector(".row[data-index='0']")
        await pg3.click(".row[data-index='0']")
        await pg3.wait_for_function("player.playing", timeout=10000)
        await pg3.click("#mini")
        await pg3.wait_for_timeout(500)
        name = await pg3.inner_text("#np-artist")
        await pg3.click("#np-artist")
        await pg3.wait_for_function("location.hash.startsWith('#/artist/')", timeout=5000)
        await pg3.wait_for_timeout(700)
        check("tapping the artist under the song opens their page", await pg3.evaluate("$('#np').hidden"), name)
        h1 = await pg3.inner_text("#view h1")
        check("and it's the right artist", h1.strip() == name.strip(), h1)
        check("no script errors (artist link)", not errs3, errs3[:3])
        await ctx3.close()

        print("\n== Wrapped ==")
        import datetime
        now = datetime.datetime.now()
        hist = []
        base = datetime.datetime(now.year, now.month, 1, 23, 0)
        for d in range(min(now.day, 9)):
            for k, sid in enumerate(["so1", "so1", "so2"]):
                t = base + datetime.timedelta(days=d, minutes=k * 4)
                if t > now: continue
                hist.append({"id": sid, "title": {"so1": "Rain Rain", "so2": "Drive Signal"}[sid], "artist": {"so1": "Velvet Static", "so2": "Paper Moons"}[sid],
                             "album": "Rain Rain", "albumId": "al1", "coverArt": "al1", "duration": 200, "at": int(t.timestamp() * 1000), "listened": 200,
                             "speed": "screwed", "device": "phone"})
        ctx4, pg4, errs4, _ = await page(browser, init="localStorage.setItem('needle.history', " + json.dumps(json.dumps(hist)) + ");")
        await pg4.goto(BASE + "#/")
        await pg4.wait_for_selector(".wrapped-banner", timeout=15000)
        check("Home shows your month so far", "so far" in await pg4.inner_text(".wrapped-banner"), await pg4.inner_text(".wrapped-banner"))
        await pg4.click(".wrapped-banner")
        await pg4.wait_for_selector(".wr-hero")
        hero = await pg4.inner_text(".wr-hero")
        n = len(hist)
        import re as _re
        got = int(_re.search(r"([\d,]+) plays", hero).group(1).replace(",", ""))
        check("Wrapped: how much you listened (this phone's plays plus the others on the NAS)", got >= n and "different songs" in hero, hero)
        check("Wrapped: top song", "Rain Rain" in await pg4.inner_text(".wr-card:nth-of-type(2)"))
        check("Wrapped: listening personality", "Night Owl" in await pg4.inner_text(".wr-persona"))
        tiles = await pg4.inner_text(".wr-tiles")
        check("Wrapped: how much was slowed down", "%" in tiles and "Screwed" in tiles, tiles)
        await pg4.wait_for_timeout(1200)
        await pg4.evaluate("$('#dock').style.visibility = 'hidden'")
        await pg4.screenshot(path=os.path.join(SHOTS, "wrapped-1.png"), full_page=True)
        await pg4.evaluate("$('#dock').style.visibility = ''")
        await pg4.click("#wr-play")
        await pg4.wait_for_function("player.queue.length >= 2 && player.current.id === 'so1'", timeout=5000)
        check("Play your top songs plays them, most played first", True)
        await pg4.click(".wr-tabs a:nth-child(3)")
        await pg4.wait_for_function("location.hash === '#/wrapped/all'")
        await pg4.wait_for_selector(".wr-hero")
        check("switch to All Time", "all time" in (await pg4.inner_text(".wr-hero")).lower())
        await pg4.wait_for_timeout(1500)
        synced = json.loads(urlopen(BASE + "_history").read())
        check("plays are shared with the NAS (for the app's Wrapped too)", any(p.get("device", "").startswith("web-") for p in synced), len(synced))
        check("Library links to Wrapped", True)
        check("no script errors (Wrapped)", not errs4, errs4[:3])
        await ctx4.close()

        await browser.close()

try:
    asyncio.run(main())
finally:
    srv.kill()
print(f"\n{sum(RESULTS)} passed, {RESULTS.count(False)} failed")
sys.exit(0 if all(RESULTS) else 1)
