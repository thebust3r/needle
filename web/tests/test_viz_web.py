"""Browser tests for the GPU visualizer: full-resolution fullscreen, every style draws, customizing,
reactivity, quiet-song boost, touch. Starts its own fake server."""
import asyncio, os, subprocess, sys, time
from urllib.request import urlopen
from playwright.async_api import async_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.join(HERE, "..", "site")
SHOTS = os.environ.get("SHOTS", os.path.join(HERE, "shots"))
os.makedirs(SHOTS, exist_ok=True)
PORT = 8802
BASE = f"http://127.0.0.1:{PORT}/"
RESULTS = []
def check(name, cond, detail=""):
    RESULTS.append(bool(cond)); print(("PASS " if cond else "FAIL ") + name + (f"   [{detail}]" if detail else ""), flush=True)

srv = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_server.py"), SITE], env=dict(os.environ, PORT=str(PORT)),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(60):
    try: urlopen(BASE); break
    except Exception: time.sleep(0.1)

BRIGHT = """(sel) => { const c = document.querySelector(sel); const t = document.createElement('canvas'); t.width = t.height = 32;
  const g = t.getContext('2d'); g.drawImage(c, 0, 0, 32, 32); const d = g.getImageData(0, 0, 32, 32).data; let s = 0;
  for (let i = 0; i < d.length; i += 4) s += d[i] + d[i + 1] + d[i + 2]; return s / (32 * 32 * 3); }"""
REGION = """([sel, x, y]) => { const c = document.querySelector(sel); const t = document.createElement('canvas'); t.width = t.height = 64;
  const g = t.getContext('2d'); g.drawImage(c, 0, 0, 64, 64); const px = Math.round(x * 63), py = Math.round(y * 63);
  const d = g.getImageData(Math.max(0, px - 8), Math.max(0, py - 8), 16, 16).data; let s = 0;
  for (let i = 0; i < d.length; i += 4) s += d[i] + d[i + 1] + d[i + 2]; return s / (16 * 16 * 3); }"""


async def page(browser, cap="0.35", dpr=2):
    ctx = await browser.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=dpr, is_mobile=True, has_touch=True)
    await ctx.add_init_script("if (!sessionStorage.getItem('seeded')) { sessionStorage.setItem('seeded','1');"
                              "localStorage.setItem('needle.cfg', JSON.stringify({user:'mason',pass:'pw'}));"
                              "localStorage.setItem('needle.weatherOn','false'); localStorage.setItem('needle.vizAuto','false');"
                              f"localStorage.setItem('needle.vizCap','{cap}'); }}")
    pg = await ctx.new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" and "favicon" not in m.text else None)
    await pg.goto(BASE + "#/album/al1")
    await pg.wait_for_selector(".row[data-index='0']")
    await pg.click(".row[data-index='0']")
    await pg.wait_for_function("player.playing && player.time() > 0.3", timeout=10000)
    await pg.click("#mini")
    await pg.wait_for_timeout(700)
    await pg.evaluate("vizUI.toggle()")
    await pg.wait_for_timeout(800)
    return ctx, pg, errs


async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"])

        print("\n== Sharp at full size ==")
        ctx, pg, errs = await page(browser, cap="1", dpr=3)
        check("drawn on the graphics chip (WebGL)", await pg.evaluate("Viz.gpu"))
        check("smooth trails (16-bit color, no banding)", await pg.evaluate("Viz.highPrecision"))
        # open fullscreen and read the size on its first frame (this test machine draws in software, so the
        # smoothness governor would step it down later; a phone's graphics chip doesn't need that)
        size = await pg.evaluate("""new Promise((res) => { document.querySelector('#viz-full').click();
          requestAnimationFrame(() => requestAnimationFrame(() => { const c = document.querySelector('#viz-big');
            res([c.width, c.height, c.clientWidth * devicePixelRatio, c.clientHeight * devicePixelRatio]); })); })""")
        check("fullscreen draws at the screen's full resolution", size[0] == size[2] and size[1] == size[3], f"{size[0]}x{size[1]} for a {size[2]:.0f}x{size[3]:.0f} screen")
        check("(the old one drew 440 px tall and stretched it)", size[1] > 2000, f"{size[1]} px tall")
        await pg.keyboard.press("Escape")
        await ctx.close()

        ctx, pg, errs = await page(browser)
        print("\n== Every style draws and moves ==")
        for i in range(7):
            name = await pg.evaluate(f"Viz.setMode({i}).name")
            await pg.wait_for_timeout(900)
            a = await pg.evaluate(BRIGHT, "#viz")
            await pg.wait_for_timeout(250)
            b = await pg.evaluate(BRIGHT, "#viz")
            check(f"{name}: lit up and moving", a > 6 and abs(a - b) > 0.05, f"brightness {a:.1f} -> {b:.1f}")

        print("\n== Reacts ==")
        await pg.evaluate("Viz.setMode(0)")
        await pg.wait_for_timeout(1200)
        f1 = await pg.evaluate("Viz.features()")
        check("bass, mids and highs are all picked up", f1["bass"] > 0.2 and f1["mid"] > 0.1 and f1["high"] > 0.02, f"{f1['bass']:.2f} / {f1['mid']:.2f} / {f1['high']:.2f}")
        await pg.evaluate("player.el.volume = 0.2")
        await pg.wait_for_timeout(2500)
        quiet = await pg.evaluate("Viz.features()")
        raw_drop = sum(quiet["levels"][:6]) / max(1e-6, sum(f1["levels"][:6]))
        shown_drop = quiet["bass"] / max(1e-6, f1["bass"])
        check("a quiet song still moves it (boosted)", shown_drop > raw_drop * 1.15 and quiet["bass"] > 0.15,
              f"raw bass fell to {raw_drop:.0%}, shown bass only to {shown_drop:.0%}")
        await pg.evaluate("player.el.volume = 1")
        await pg.evaluate("Viz.set('intensity', 0.5)")
        await pg.wait_for_timeout(1500)
        low = await pg.evaluate("Viz.features().bass")
        await pg.evaluate("Viz.set('intensity', 2)")
        await pg.wait_for_timeout(1500)
        high = await pg.evaluate("Viz.features().bass")
        check("Reactivity slider: Hype reacts much more than Chill", high > low * 2.5, f"{low:.2f} vs {high:.2f}")
        await pg.evaluate("Viz.set('intensity', 1)")
        fl0 = await pg.evaluate("Viz.features().flow")
        await pg.wait_for_timeout(1000)
        fl1 = await pg.evaluate("Viz.features().flow")
        check("always flowing (the current keeps moving)", fl1 > fl0 + 0.2, f"{fl0:.2f} -> {fl1:.2f}")

        print("\n== Customize ==")
        await pg.click("#viz-custom")
        await pg.wait_for_selector(".viz-panel")
        await pg.wait_for_timeout(400)
        await pg.screenshot(path=os.path.join(SHOTS, "viz-customize.png"))
        styles = await pg.eval_on_selector_all(".vp-styles button", "bs => bs.map(b => b.textContent)")
        check("seven styles plus Auto", styles == ["Auto", "Warp Ring", "Prism", "Hyperspace", "Melt", "Equalizer", "Nebula", "Mandala"], styles)
        themes = await pg.eval_on_selector_all(".vp-themes button", "bs => bs.map(b => b.textContent.trim())")
        check("color themes", len(themes) == 7 and "Fire" in themes and "Album Colors" in themes, themes)
        await pg.click(".vp-styles button:text('Nebula')")
        check("picking a style switches to it", await pg.evaluate("Viz.mode.name") == "Nebula" and not await pg.evaluate("Viz.auto"))
        await pg.click(".vp-themes button:text('Fire')")
        await pg.wait_for_timeout(1500)
        await pg.eval_on_selector(".vp-slider input[data-key='trails']", "e => { e.value = 0.95; e.dispatchEvent(new Event('input')); }")
        await pg.eval_on_selector(".vp-slider input[data-key='speed']", "e => { e.value = 1.6; e.dispatchEvent(new Event('input')); }")
        await pg.click("#vp-mirror")
        st = await pg.evaluate("Viz.settings")
        check("sliders and the mirror change the settings", st["theme"] == "fire" and abs(st["trails"] - 0.95) < 0.02 and abs(st["speed"] - 1.6) < 1e-6 and st["mirror"], st)
        words = await pg.eval_on_selector_all(".vp-slider em", "es => es.map(e => e.textContent)")
        check("sliders say what they do", words[1] == "Long" and words[2] == "Fast", words)
        await pg.click(".vp-done")
        await pg.reload()
        await pg.wait_for_function("typeof Viz !== 'undefined'")
        st2 = await pg.evaluate("Viz.settings")
        check("your setup is remembered", st2 == st, st2)
        await pg.evaluate("Viz.resetSettings()")
        check("Reset goes back to the defaults", await pg.evaluate("Viz.settings.theme === 'album' && Viz.settings.intensity === 1 && !Viz.settings.mirror"))
        check("no script errors", not errs, errs[:3])
        await ctx.close()

        print("\n== Touch in fullscreen ==")
        ctx, pg, errs = await page(browser)
        await pg.evaluate("Viz.setMode(3)")            # Melt: dark in the corners, so a burst shows clearly
        await pg.click("#viz-full")
        await pg.wait_for_timeout(1500)
        check("tip explains the touch controls", "Drag to swirl" in await pg.inner_text("#vf-tip"))
        before = await pg.evaluate(REGION, ["#viz-big", 0.25, 0.15])
        box = await pg.locator("#viz-big").bounding_box()
        await pg.mouse.click(box["x"] + box["width"] * 0.25, box["y"] + box["height"] * 0.15)
        await pg.wait_for_timeout(220)
        after = await pg.evaluate(REGION, ["#viz-big", 0.25, 0.15])
        check("tap makes a burst of light where you touched", after > before + 4, f"{before:.1f} -> {after:.1f}")
        x0, y0 = box["x"] + box["width"] * 0.5, box["y"] + box["height"] * 0.5
        await pg.mouse.move(x0, y0)
        await pg.mouse.down()
        for k in range(12):
            await pg.mouse.move(x0 + 80 * __import__("math").cos(k / 2), y0 + 80 * __import__("math").sin(k / 2))
            await pg.wait_for_timeout(16)
        await pg.mouse.up()
        check("dragging swirls it", await pg.evaluate("Viz.touchSwirl") > 0.2, await pg.evaluate("Viz.touchSwirl"))
        await pg.click("#vf-next")
        check("arrows change the style", await pg.evaluate("Viz.mode.name") == "Equalizer")
        await pg.wait_for_timeout(1200)
        await pg.screenshot(path=os.path.join(SHOTS, "viz-full.png"))
        check("no script errors", not errs, errs[:3])
        await browser.close()

try:
    asyncio.run(main())
finally:
    srv.kill()
print(f"\n{sum(RESULTS)} passed, {RESULTS.count(False)} failed")
sys.exit(0 if all(RESULTS) else 1)
