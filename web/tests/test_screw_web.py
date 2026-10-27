"""Browser test of slowed / chopped & screwed on the web player. Starts its own fake server."""
import asyncio, os, subprocess, sys, time
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


async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"])
        ctx = await browser.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=2, is_mobile=True, has_touch=True)
        await ctx.add_init_script("if (!sessionStorage.getItem('seeded')) { sessionStorage.setItem('seeded','1');"
                                  "localStorage.setItem('needle.cfg', JSON.stringify({user:'mason',pass:'pw'}));"
                                  "localStorage.setItem('needle.eq', JSON.stringify({enabled:false}));"
                                  "localStorage.setItem('needle.weatherOn','false'); }")
        pg = await ctx.new_page()
        errs = []
        pg.on("pageerror", lambda e: errs.append(str(e)))
        pg.on("console", lambda m: errs.append(m.text) if m.type == "error" and "favicon" not in m.text else None)

        await pg.goto(BASE + "#/album/al1")
        await pg.wait_for_selector(".row[data-index='0']")
        await pg.click(".row[data-index='0']")
        await pg.wait_for_function("player.playing && player.time() > 0.3", timeout=10000)
        await pg.click("#mini")
        await pg.wait_for_timeout(500)
        check("chip is quiet when off", await pg.inner_text("#np-screw span") == "")
        check("EQ off: audio not routed through Web Audio yet", not await pg.evaluate("player.el.routed"))

        await pg.click("#np-screw")
        await pg.wait_for_selector(".screw-panel")
        await pg.screenshot(path=os.path.join(SHOTS, "screw-1-panel.png"))
        await pg.click("[data-speed='screwed']")
        await pg.wait_for_timeout(300)
        st = await pg.evaluate("({r: player.el.playbackRate, p: player.el.preservesPitch})")
        check("Screwed plays at 80%", abs(st["r"] - 0.8) < 1e-6, st)
        check("and lets the pitch drop (like a record)", st["p"] is False, st)
        await pg.click("[data-chops='heavy']")
        await pg.wait_for_timeout(500)
        check("chops route the audio through the chopper", await pg.evaluate("player.el.routed && !!audio.chop"))
        check("chip says Screwed & Chopped", await pg.inner_text("#np-screw span") == "Screwed & Chopped")
        await pg.click(".sp-done")
        # the test song: kick every 0.5 s = 120 BPM, slowed to 80% = 96 BPM as heard
        await pg.wait_for_function("screw.stats && screw.stats.bpm > 0 && screw.stats.confidence > 0.25", timeout=20000)
        bpm = await pg.evaluate("screw.stats.bpm")
        check("finds the slowed-down beat (120 BPM x 0.8 = 96)", abs(bpm - 96) < 2.5 or abs(bpm - 48) < 1.5, f"{bpm:.1f}")
        await pg.wait_for_function("screw.stats && screw.stats.chops > 0", timeout=30000)
        check("chops happen", True, f"{await pg.evaluate('screw.stats.chops')} so far")
        await pg.click("#np-screw")
        await pg.wait_for_timeout(700)
        txt = await pg.inner_text("#sp-status")
        check("panel shows it's locked on the beat", txt.startswith("Locked on beat") and "BPM" in txt, txt)
        await pg.screenshot(path=os.path.join(SHOTS, "screw-3-status.png"))
        await pg.click(".sp-done")
        await pg.screenshot(path=os.path.join(SHOTS, "screw-2-np.png"))

        # live mode: you tap the chops
        check("pads hidden unless Live is on", await pg.evaluate("$('#np-pads').hidden"))
        await pg.click("#np-screw")
        await pg.click("[data-chops='live']")
        await pg.wait_for_timeout(300)
        await pg.screenshot(path=os.path.join(SHOTS, "screw-4-live-panel.png"))
        await pg.click(".sp-done")
        check("Live shows the pads on Now Playing", await pg.is_visible("#np-pads"))
        check("chip says Screwed + Live Chops", await pg.inner_text("#np-screw span") == "Screwed + Live Chops")
        before = await pg.evaluate("screw.stats.chops")
        await pg.wait_for_timeout(4500)
        check("Live never chops on its own", await pg.evaluate("screw.stats.chops") == before, f"{before} -> {await pg.evaluate('screw.stats.chops')}")
        await pg.wait_for_function("screw.stats && screw.stats.confidence > 0.15", timeout=20000)
        await pg.click("[data-move='stutter']")
        await pg.wait_for_function("livePads.log.length >= 1", timeout=3000)
        check("tapping a pad fires that move", await pg.evaluate("JSON.stringify(livePads.log[0])") == '["stutter",true]', await pg.evaluate("JSON.stringify(livePads.log)"))
        await pg.wait_for_timeout(2500)
        await pg.keyboard.press("4")
        await pg.wait_for_function("livePads.log.length >= 2", timeout=3000)
        check("number keys work as pads", await pg.evaluate("JSON.stringify(livePads.log[1])") == '["runBack",true]', await pg.evaluate("JSON.stringify(livePads.log)"))
        await pg.wait_for_timeout(2500)
        box = await pg.locator("[data-move='loop']").bounding_box()
        await pg.mouse.move(box["x"] + 20, box["y"] + 20)
        await pg.mouse.down()
        await pg.wait_for_timeout(1800)
        await pg.screenshot(path=os.path.join(SHOTS, "screw-5-live-pads.png"))
        await pg.mouse.up()
        await pg.wait_for_timeout(1500)
        hist = await pg.evaluate("JSON.stringify(livePads.log)")
        check("holding Repeat loops the beat", '["loop",true]' in hist, hist)
        await pg.evaluate("screw.set(null, 'heavy')")
        check("back to Heavy hides the pads", await pg.evaluate("$('#np-pads').hidden"))

        await pg.click("#np-next")
        await pg.wait_for_function("player.i === 1 && player.playing", timeout=10000)
        check("next song stays screwed", abs(await pg.evaluate("player.el.playbackRate") - 0.8) < 1e-6)
        await pg.reload()
        await pg.wait_for_function("typeof screw !== 'undefined'")
        check("setting is remembered", await pg.evaluate("screw.speed === 'screwed' && screw.chops === 'heavy'"))
        await pg.evaluate("audio.ensure(); screw.set('off', 'off')")
        await pg.goto(BASE + "#/album/al2")
        await pg.wait_for_selector(".row[data-index='0']")
        await pg.click(".row[data-index='0']")
        await pg.wait_for_function("player.playing && player.time() > 0.3", timeout=10000)
        check("off = normal speed again", await pg.evaluate("player.el.playbackRate") == 1)
        check("no script errors", not errs, errs[:3])
        await browser.close()

try:
    asyncio.run(main())
finally:
    srv.kill()
print(f"\n{sum(RESULTS)} passed, {RESULTS.count(False)} failed")
sys.exit(0 if all(RESULTS) else 1)
