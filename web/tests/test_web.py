"""Needle web: visualizer benchmarks, lyrics, updates and regression tests.
Start the fake server first:  python3 fake_server.py ../site   (serves on :8796)
Then:                         python3 test_web.py"""
import asyncio
import json
import os
import sys

from playwright.async_api import async_playwright

BASE = "http://localhost:8796/"
SITE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "site")
RESULTS = []


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name + (f"   [{detail}]" if detail else ""), flush=True)


async def new_page(browser, reduced=False, w=390, h=844, viz=False, lyr=False):
    ctx = await browser.new_context(viewport={"width": w, "height": h}, device_scale_factor=3, is_mobile=True,
                                    has_touch=True, reduced_motion="reduce" if reduced else "no-preference")
    await ctx.add_init_script(   # starting settings, applied once per test (not on every reload)
        "if (!sessionStorage.getItem('seeded')) { sessionStorage.setItem('seeded', '1');"
        "localStorage.setItem('needle.cfg', JSON.stringify({user:'mason',pass:'pw'}));"
        f"localStorage.setItem('needle.vizOn', '{str(viz).lower()}'); localStorage.setItem('needle.lyricsOn', '{str(lyr).lower()}');"
        "localStorage.setItem('needle.vizAuto', 'false'); localStorage.setItem('needle.vizMode', '0'); }")
    await ctx.route("https://*.open-meteo.com/**", lambda r: r.fulfill(status=200, content_type="application/json",
                    body='{"current":{"temperature_2m":60,"weather_code":0,"is_day":1}}'))
    pg = await ctx.new_page()
    pg.want_viz = viz
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)
    return ctx, pg, errs


async def play(pg, album="al1", idx=0, open_np=True):
    if await pg.evaluate("document.querySelector('#np') && !document.querySelector('#np').hidden"):
        await pg.click("#np-close")             # like a person: close Now Playing before picking another album
        await pg.wait_for_timeout(450)
    await pg.goto(BASE + f"#/album/{album}")
    await pg.wait_for_selector(".row[data-index='0']")
    await pg.click(f".row[data-index='{idx}']")
    await pg.wait_for_function("player.playing && player.time() > 0.3", timeout=10000)
    if open_np:
        await pg.click("#mini")
        await pg.wait_for_timeout(500)
        if getattr(pg, "want_viz", False) and not await pg.evaluate("vizUI.on"):
            await pg.click("#np-stage")          # Now Playing opens on the art; tap it for the visualizer
            await pg.wait_for_timeout(300)


WINDOW = """(() => { const s = Viz.stats, d = [...s.drawMs].sort((a, b) => a - b), iv = s.intervals;
  const avg = (a) => a.reduce((x, y) => x + y, 0) / Math.max(1, a.length);
  return { frames: s.frames, drawAvg: avg(d), drawP95: d[Math.floor(d.length * 0.95)] || 0, fps: 1000 / avg(iv),
           beats: s.beats, flashes: s.flashes, flashLog: [...s.flashLog], quality: s.quality }; })()"""


async def measure(pg, ms):
    await pg.evaluate("Viz.resetStats()")
    await pg.wait_for_timeout(ms)
    return await pg.evaluate(WINDOW)


def max_per_second(log):
    return max((sum(1 for u in log if t <= u < t + 1000) for t in log), default=0)


BRIGHTNESS = """(() => { const c = document.querySelector(Viz.running && !document.querySelector('#vizfull').hidden ? '#viz-big' : '#viz');
  const t = document.createElement('canvas'); t.width = t.height = 24; const g = t.getContext('2d');
  g.drawImage(c, 0, 0, 24, 24); const d = g.getImageData(0, 0, 24, 24).data; let s = 0;
  for (let i = 0; i < d.length; i += 4) s += d[i] + d[i + 1] + d[i + 2]; return s / (24 * 24 * 3); })()"""


async def brightness_series(pg, n=30, gap=100):
    out = []
    for _ in range(n):
        out.append(await pg.evaluate(BRIGHTNESS))
        await pg.wait_for_timeout(gap)
    return out


def variance(xs):
    m = sum(xs) / len(xs)
    return sum((x - m) ** 2 for x in xs) / len(xs)


async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required", "--enable-precise-memory-info"])

        # ------------------------------------------------------------ visualizer: basics
        print("\n== Visualizer: tap, styles, full screen ==")
        ctx, pg, errs = await new_page(browser)
        await play(pg)
        check("art shows first (visualizer off by default)", not await pg.evaluate("vizUI.on") and not await pg.evaluate("Viz.running"))
        await pg.click("#np-stage")
        await pg.wait_for_timeout(600)
        check("tapping the album art flips to the visualizer", await pg.evaluate("vizUI.on && Viz.running && document.querySelector('#np-stage').classList.contains('viz-on')"))
        check("visualizer is listening to the actual music", await pg.evaluate("Viz.isLive()"))
        box = await pg.locator("#np-stage").bounding_box()
        await pg.mouse.move(box["x"] + 60, box["y"] + 100)
        await pg.mouse.down()
        await pg.mouse.move(box["x"] + 200, box["y"] + 110, steps=6)
        await pg.mouse.up()
        await pg.wait_for_timeout(200)
        check("a swipe across the art does NOT flip it", await pg.evaluate("vizUI.on"))
        await pg.click("#np-stage")
        await pg.wait_for_timeout(500)
        check("tapping again flips back to the art and stops drawing", not await pg.evaluate("vizUI.on") and not await pg.evaluate("Viz.running"))
        await pg.click("#np-stage")
        await pg.wait_for_timeout(300)
        await pg.click("#np-close")
        await pg.wait_for_timeout(450)
        await pg.click("#mini")
        await pg.wait_for_timeout(500)
        check("reopening Now Playing shows the album art again", not await pg.evaluate("vizUI.on") and not await pg.evaluate("Viz.running"))
        await pg.click("#np-stage")
        await pg.wait_for_timeout(400)
        check("one tap brings the visualizer back", await pg.evaluate("vizUI.on && Viz.running"))
        labels = []
        for _ in range(6):
            await pg.click("#viz-mode")
            labels.append(await pg.inner_text("#viz-mode"))
        check("style button cycles every style and Auto", labels == ["Prism", "Hyperspace", "Melt", "Auto · Melt", "Warp Ring", "Prism"], " → ".join(labels))
        await pg.click("#viz-full")
        await pg.wait_for_timeout(700)
        check("full-screen button opens the big visualizer", await pg.evaluate("!document.querySelector('#vizfull').hidden && Viz.running"))
        before = await pg.evaluate("Viz.mode.name")
        await pg.keyboard.press("ArrowRight")
        check("arrow keys change style in full screen", await pg.evaluate("Viz.mode.name") != before)
        await pg.wait_for_timeout(2800)
        check("full-screen controls fade out when idle", await pg.evaluate("document.querySelector('#vizfull').classList.contains('idle')"))
        await pg.keyboard.press("Escape")
        await pg.wait_for_timeout(300)
        check("Escape closes full screen and the small one keeps going", await pg.evaluate("document.querySelector('#vizfull').hidden && Viz.running"))
        await pg.click("#np-close")
        await pg.wait_for_timeout(500)
        check("closing Now Playing stops the visualizer (no battery drain)", not await pg.evaluate("Viz.running"))
        check("no errors", not errs, "; ".join(errs[:3]))
        await ctx.close()

        # ------------------------------------------------------------ visualizer: reacting to music
        print("\n== Visualizer: reacts to the music ==")
        ctx, pg, errs = await new_page(browser, viz=True)
        await play(pg)
        await pg.wait_for_timeout(800)
        m = await measure(pg, 6000)
        bps = m["beats"] / 6
        check("beat detection matches the test track's 120 BPM kick", 1.5 <= bps <= 2.5, f"{bps:.2f} beats/sec")
        live_bass = await pg.evaluate("Viz.features().bass")
        playing = await brightness_series(pg)
        await pg.click("#np-play")
        await pg.wait_for_timeout(1200)
        check("pausing switches it to calm idle motion", not await pg.evaluate("Viz.isLive()") and await pg.evaluate("Viz.running"))
        idle_bass = await pg.evaluate("Viz.features().bass")
        paused = await brightness_series(pg)
        check("bass level is higher with music than idle", live_bass > idle_bass, f"{live_bass:.2f} vs {idle_bass:.2f}")
        check("picture pulses much more with music than when paused", variance(playing) > variance(paused) * 2,
              f"variance {variance(playing):.1f} vs {variance(paused):.1f}")
        check("idle picture is still alive (not frozen)", variance(paused) > 0.01 or len(set(round(x, 2) for x in paused)) > 3)
        await pg.click("#np-play")
        await pg.wait_for_timeout(500)
        # EQ off = no audio routing on iPhone-safe mode
        await pg.evaluate("eq.enabled = false; saveEQ(); audio.apply(); player.reroute();")
        await pg.wait_for_timeout(1800)
        check("with the EQ off it explains why it isn't reacting", await pg.evaluate("!document.querySelector('#viz-hint').hidden && !Viz.isLive()"))
        await pg.evaluate("eq.enabled = true; saveEQ(); audio.apply(); player.reroute();")
        await pg.wait_for_timeout(1800)
        check("turning the EQ back on makes it react again", await pg.evaluate("document.querySelector('#viz-hint').hidden && Viz.isLive()"))
        check("no errors", not errs, "; ".join(errs[:3]))
        await ctx.close()

        # ------------------------------------------------------------ visualizer: safety
        print("\n== Visualizer: flashing safety and Reduce Motion ==")
        ctx, pg, errs = await new_page(browser, viz=True)
        await play(pg)
        await pg.wait_for_timeout(500)
        m = await measure(pg, 10000)
        check("never more than 3 flashes in any second (WCAG 2.3.1)", max_per_second(m["flashLog"]) <= 3,
              f"max {max_per_second(m['flashLog'])}/sec, {m['flashes']} total in 10s")
        await ctx.close()
        ctx, pg, errs = await new_page(browser, viz=True, reduced=True)
        await play(pg)
        await pg.wait_for_timeout(500)
        m = await measure(pg, 6000)
        check("Reduce Motion: zero flashes", m["flashes"] == 0, f"{m['flashes']} flashes, {m['beats']} beats still detected")
        check("Reduce Motion: still draws and reacts", m["frames"] > 100 and m["beats"] > 3)
        check("no errors", not errs, "; ".join(errs[:3]))
        await ctx.close()

        # ------------------------------------------------------------ visualizer: performance
        print("\n== Visualizer: benchmarks ==")
        ctx, pg, errs = await new_page(browser, viz=True)
        cdp = await ctx.new_cdp_session(pg)
        await play(pg)
        for i in range(4):
            name = await pg.evaluate(f"Viz.setMode({i}).name")
            await pg.wait_for_timeout(600)
            m = await measure(pg, 4000)
            check(f"{name}: smooth on a normal phone", m["fps"] >= 55 and m["drawAvg"] <= 6 and m["drawP95"] <= 12,
                  f"{m['fps']:.0f} fps, draw avg {m['drawAvg']:.2f} ms, p95 {m['drawP95']:.2f} ms")
        for rate, label, need in [(4, "mid-range phone (4x slower CPU)", 45), (6, "old phone (6x slower CPU)", 30)]:
            await cdp.send("Emulation.setCPUThrottlingRate", {"rate": rate})
            worst = None
            for i in range(4):
                name = await pg.evaluate(f"Viz.setMode({i}).name")
                await pg.wait_for_timeout(2500)          # let the quality governor settle
                m = await measure(pg, 3000)
                worst = m if worst is None or m["fps"] < worst["fps"] else worst
            check(f"{label}: every style stays watchable", worst["fps"] >= need,
                  f"slowest {worst['fps']:.0f} fps, quality {worst['quality']:.2f}")
        await cdp.send("Emulation.setCPUThrottlingRate", {"rate": 1})

        # memory over a long session, cycling styles and full screen
        await cdp.send("HeapProfiler.enable")
        await cdp.send("HeapProfiler.collectGarbage")
        await pg.wait_for_timeout(500)
        heap0 = await pg.evaluate("performance.memory.usedJSHeapSize")
        for k in range(12):
            await pg.evaluate(f"Viz.setMode({k % 4})")
            if k % 4 == 3:
                await pg.click("#viz-full")
                await pg.wait_for_timeout(1500)
                await pg.keyboard.press("Escape")
            await pg.wait_for_timeout(1500)
        await cdp.send("HeapProfiler.collectGarbage")
        await pg.wait_for_timeout(500)
        heap1 = await pg.evaluate("performance.memory.usedJSHeapSize")
        growth = (heap1 - heap0) / 1e6
        check("no memory leak over a 25-second session", growth < 2.0, f"heap {heap0/1e6:.1f} → {heap1/1e6:.1f} MB ({growth:+.2f} MB)")

        await pg.set_viewport_size({"width": 844, "height": 390})
        await pg.wait_for_timeout(800)
        res0 = await pg.evaluate("Viz.stats.resizes")
        await pg.set_viewport_size({"width": 390, "height": 844})
        await pg.wait_for_timeout(800)
        check("rotating the phone resizes cleanly", await pg.evaluate("Viz.stats.resizes") > res0 and not errs)
        check("no errors", not errs, "; ".join(errs[:3]))
        await ctx.close()

        # ------------------------------------------------------------ lyrics
        print("\n== Synced lyrics ==")
        ctx, pg, errs = await new_page(browser, viz=True)
        await pg.goto(BASE)
        await pg.wait_for_selector(".shelf .card")
        parsed = await pg.evaluate("""(() => { const p = lyrics.parseLRC; return {
            basic: p('[00:12.50]Hello'), colon: p('[01:02:30]Colon ms'), multi: p('[00:01.5][00:03]Twice'),
            offset: p('[offset:+500]\\n[00:10.00]Shifted'), junk: p('no stamps here\\n[ar:Artist]') }; })()""")
        check("LRC: basic timestamp", parsed["basic"] == [{"t": 12.5, "text": "Hello"}])
        check("LRC: mm:ss:xx style", abs(parsed["colon"][0]["t"] - 62.3) < 1e-6)
        check("LRC: one line with two timestamps appears twice, in order", [round(x["t"], 2) for x in parsed["multi"]] == [1.5, 3.0])
        check("LRC: [offset] tag is applied", abs(parsed["offset"][0]["t"] - 9.5) < 1e-6)
        check("LRC: tag-only and plain lines are ignored", parsed["junk"] == [])
        await play(pg)                                          # album al1 has lyrics in its files
        await pg.click("#np-lyrics")
        await pg.wait_for_selector(".ly-line")
        check("Lyrics button swaps the art for lyrics and pauses the visualizer",
              await pg.evaluate("!document.querySelector('#lyrics').hidden && document.querySelector('#np-stage').hidden && !Viz.running"))
        check("lyrics from your own files are used first", "your files" in await pg.inner_text(".ly-source"))
        await pg.evaluate("player.seek(10.05)")
        await pg.wait_for_timeout(700)
        check("the line being sung is highlighted", await pg.inner_text(".ly-line.now") == "File lyric 5", await pg.inner_text(".ly-line.now"))
        check("earlier lines are marked as already sung", await pg.evaluate("document.querySelectorAll('.ly-line.past').length") == 4)
        await pg.click(".ly-line[data-i='7']")
        await pg.wait_for_timeout(700)
        t = await pg.evaluate("player.time()")
        check("tapping a line jumps the song there", 17.4 <= t <= 18.6, f"{t:.2f}s (line starts at 17.5s)")
        check("and that line lights up", await pg.inner_text(".ly-line.now") == "File lyric 8")
        scroll = await pg.evaluate("document.querySelector('#lyrics-body').scrollTop")
        check("lyrics scroll to keep the current line in view", scroll > 0, f"scrollTop {scroll}")
        await pg.click("#np-lyrics")
        await pg.wait_for_timeout(400)
        check("turning lyrics off brings back the visualizer", await pg.evaluate("document.querySelector('#lyrics').hidden && Viz.running"))

        await play(pg, album="al0")                             # titles from LRCLIB (fake), no file lyrics
        title = await pg.evaluate("player.current.title")
        await pg.click("#np-lyrics")
        await pg.wait_for_function("lyrics.current && !lyrics.current.loading", timeout=8000)
        src = await pg.evaluate("lyrics.current.source || (lyrics.current.none ? 'none' : '?')")
        expect_lrclib = "Drive" in title or "Echo" in title
        if expect_lrclib:
            check("falls back to LRCLIB through the NAS when files have none", src == "LRCLIB" and await pg.evaluate("lyrics.current.synced"), f"'{title}' → {src}")
        else:
            check("shows 'No lyrics found' when nobody has them", src == "none" and "No lyrics found" in await pg.inner_text("#lyrics-body"), f"'{title}' → {src}")
        cached = await pg.evaluate("Object.keys(localStorage).filter(k => k.startsWith('needle.lyr.')).length")
        check("lyrics are cached so they load instantly next time", cached >= 2, f"{cached} cached")
        # make sure both branches get covered
        await pg.evaluate("""(async () => {
            const t = { id: 'x-none', title: 'Totally Unknown Song', artist: 'Nobody', album: 'None', duration: 30 };
            player.queue.splice(player.i + 1, 0, t); })()""")
        await pg.evaluate("player.skip()")
        await pg.wait_for_function("lyrics.current && !lyrics.current.loading && lyrics.current.id === 'x-none'", timeout=8000)
        check("unknown song: 'No lyrics found' message", "No lyrics found" in await pg.inner_text("#lyrics-body"))
        await pg.evaluate("""player.queue.splice(player.i + 1, 0, { id: 'x-lrclib', title: 'Drive Test', artist: 'Someone', album: 'Else', duration: 30 })""")
        await pg.evaluate("player.skip()")
        await pg.wait_for_function("lyrics.current && !lyrics.current.loading && lyrics.current.id === 'x-lrclib'", timeout=8000)
        lc = await pg.evaluate("({ src: lyrics.current.source, synced: lyrics.current.synced, n: lyrics.current.lines.length, last: lyrics.current.lines.at(-1) })")
        check("LRCLIB fallback (through the NAS) gives synced lyrics", lc["src"] == "LRCLIB" and lc["synced"] and lc["n"] == 12, json.dumps(lc))
        check("LRCLIB source is credited on screen", "LRCLIB" in await pg.inner_text(".ly-source"))
        errs[:] = [e for e in errs if "404" not in e and "Failed to load resource" not in e]   # expected: LRCLIB says "not found"
        check("no errors", not errs, "; ".join(errs[:3]))
        await ctx.close()

        # ------------------------------------------------------------ updates in the app
        print("\n== Updates ==")
        ctx, pg, errs = await new_page(browser)
        await play(pg, open_np=False)
        vfile = os.path.join(SITE, "version.txt")
        original = open(vfile).read()
        try:
            open(vfile, "w").write("9.9.9\n")
            await pg.evaluate("checkForUpdate()")
            await pg.wait_for_timeout(500)
            toast = await pg.inner_text("#toast")
            check("a newly dropped-in version is noticed while music plays", "9.9.9" in toast and await pg.evaluate("!document.querySelector('#toast').hidden"), toast)
            check("music keeps playing (no surprise reload mid-song)", await pg.evaluate("player.playing"))
        finally:
            open(vfile, "w").write(original)
        await ctx.close()

        # ------------------------------------------------------------ regression of everything else
        print("\n== Everything else still works ==")
        ctx, pg, errs = await new_page(browser)
        await pg.goto(BASE)
        await pg.wait_for_selector(".shelf .card")
        check("home screen loads album shelves", await pg.evaluate("document.querySelectorAll('.shelf .card').length") >= 10)
        await pg.goto(BASE + "#/search")
        await pg.fill("#q", "Drive")
        await pg.wait_for_timeout(900)
        check("search finds albums and songs", await pg.evaluate("document.querySelectorAll('#results .card, #results .row').length") > 0)
        await play(pg)
        await pg.click("#np-eq")
        await pg.wait_for_timeout(500)
        gbox = await pg.locator("#eq-graph").bounding_box()
        x = gbox["x"] + gbox["width"] * 0.25
        await pg.mouse.move(x, gbox["y"] + gbox["height"] / 2)
        await pg.mouse.down()
        await pg.mouse.move(x, gbox["y"] + 60, steps=6)
        await pg.mouse.up()
        check("EQ curve drag changes the real audio filter", max(await pg.evaluate("audio.filters.map(f => f.gain.value)")) > 3)
        await pg.click("#eq-done")
        await pg.click("#np-queue")
        check("queue opens", await pg.evaluate("!document.querySelector('#queue').hidden && document.querySelectorAll('#queue [data-q]').length > 0"))
        check("no errors", not errs, "; ".join(errs[:3]))
        await ctx.close()
        await browser.close()

    passed = sum(1 for _, ok in RESULTS if ok)
    print(f"\n{passed}/{len(RESULTS)} checks passed")
    return passed == len(RESULTS)


if __name__ == "__main__":
    sys.exit(0 if asyncio.run(main()) else 1)
