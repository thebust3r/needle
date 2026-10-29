"""Tests the updater exactly as embedded in docker-compose.yml."""
import os, shutil, subprocess, sys, tempfile, time, zipfile, yaml
WEB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
compose = yaml.safe_load(open(f"{WEB}/docker-compose.yml"))
cmd = compose["services"]["needle-updater"]["command"][2].replace("$$", "$")   # what Compose hands the shell
script = cmd.split("<<'EOF'\n", 1)[1].split("\nEOF\n", 1)[0]
assert script.strip() == open(f"{WEB}/updater.sh").read().strip(), "compose updater differs from updater.sh"
ng = compose["services"]["needle-web"]["command"][2].replace("$$", "$")
assert ng.split("<<'EOF'\n", 1)[1].split("\nEOF\n", 1)[0].strip() == open(f"{WEB}/nginx.conf").read().strip(), "compose nginx config differs"
assert compose["services"]["needle-web"]["volumes"] == ["/volume1/docker/needle-web:/app:ro"]
print("PASS compose embeds updater.sh and nginx.conf exactly (after $$ unescaping)")

root = tempfile.mkdtemp()
app = os.path.join(root, "app"); os.makedirs(app)
spath = os.path.join(root, "updater.sh"); open(spath, "w").write(script)
results = []
def check(name, cond):
    results.append(cond); print(("PASS " if cond else "FAIL ") + name)
def run():
    r = subprocess.run(["dash", spath], env={**os.environ, "APP": app, "ONCE": "1"}, capture_output=True, text=True, timeout=60)
    return r.stdout + r.stderr
def mkzip(name, files):
    p = os.path.join(app, "updates", name)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with zipfile.ZipFile(p, "w") as z:
        for arc, data in files.items(): z.writestr(arc, data)
    return p
site = lambda f="": os.path.join(app, "site", f)
ls = lambda d: sorted(os.listdir(os.path.join(app, "updates", d)))

out = run()
check("first run creates updates/installed, failed, backups and site", all(os.path.isdir(os.path.join(app, "updates", d)) for d in ("installed", "failed", "backups")) and os.path.isdir(site()))
check("first run explains how to install", "drop the Needle web zip" in out)

# 1. the real release zip
_ver = open(f"{WEB}/site/version.txt").read().strip()
rel = f"Platter-web-v{_ver}.zip"
shutil.copy(f"{WEB}/dist/{rel}", os.path.join(app, "updates", rel))
out = run()
check("release zip installs index.html, app.js, viz.js, lyrics.js", all(os.path.isfile(site(f)) for f in ("index.html", "app.js", "viz.js", "lyrics.js", "icons/icon-180.png")))
VER = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "site", "version.txt")).read().strip()
check(f"version.txt is {VER} and the log says so", open(site("version.txt")).read().strip() == VER and f"version {VER}" in out)
check("the import helper is installed with the site", os.path.exists(site("helper/helper.py")))
check("release zip moved to installed", len(ls("installed")) == 1 and not os.path.exists(os.path.join(app, "updates", rel)))
check("docker-compose.yml from the zip is NOT copied into site", not os.path.exists(site("docker-compose.yml")))
check("no backup on the very first install", ls("backups") == [])

# 2. nested like a GitHub download: needle-main/web/site/...
mkzip("needle-main.zip", {"needle-main/README.md": "x", "needle-main/web/site/index.html": "<p>v2</p>", "needle-main/web/site/app.js": "//2",
                          "needle-main/web/site/version.txt": "1.2.0", "needle-main/ios/Needle/index.html": "decoy deeper"})
out = run()
check("nested zip: picks the shallowest index.html (web/site), not a deeper decoy", open(site("index.html")).read() == "<p>v2</p>")
check("nested zip: old files are gone (clean swap)", not os.path.exists(site("viz.js")))
check("previous version backed up", len(ls("backups")) == 1 and os.path.isfile(os.path.join(app, "updates", "backups", ls("backups")[0], "viz.js")))

# 3. loose files, name with spaces
time.sleep(1.1)
mkzip("Needle web v3 (1).zip", {"index.html": "<p>v3</p>", "app.js": "//3", "version.txt": "1.3.0"})
run()
check("zip with loose files and spaces in its name installs", open(site("index.html")).read() == "<p>v3</p>" and any("Needle web v3 (1).zip" in f for f in ls("installed")))

# 4. broken things never touch the running version
before = open(site("index.html")).read()
p = os.path.join(app, "updates", "not-really.zip"); open(p, "w").write("this is not a zip")
mkzip("photos.zip", {"cat.jpg": "jpg"})
mkzip("half.zip", {"index.html": "<p>no app.js</p>"})
out = run()
check("corrupt zip goes to failed with a clear reason", "not-really.zip" in ls("failed") and "isn't a working zip" in out)
check("zip without index.html goes to failed", "photos.zip" in ls("failed") and "no index.html" in out)
check("zip without app.js goes to failed", "half.zip" in ls("failed") and "app.js is missing" in out)
check("running version untouched after 3 bad zips", open(site("index.html")).read() == before)
check("no temp folders left behind", not any(n.startswith(".site-") for n in os.listdir(app)))

# 5. backups capped at 5
for i in range(7):
    time.sleep(1.05)
    mkzip(f"u{i}.zip", {"index.html": f"<p>u{i}</p>", "app.js": "//"})
    run()
check("only the 5 newest backups are kept", len(ls("backups")) == 5)
check("last of 7 updates is live", open(site("index.html")).read() == "<p>u6</p>")

# 6. a zip still being copied is left alone until it stops growing
p = os.path.join(app, "updates", "slow.zip")
f = open(p, "wb"); f.write(b"PK"); f.flush()
proc = subprocess.Popen(["dash", spath], env={**os.environ, "APP": app, "ONCE": "1"}, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
time.sleep(0.8); f.write(b"more data arriving"); f.flush()
out = proc.communicate(timeout=30)[0]
check("half-copied zip is skipped (not failed, not installed)", os.path.exists(p) and "slow.zip" not in ls("failed"))
f.close(); os.remove(p)

# 7. files readable by nginx
mode_ok = all(os.stat(os.path.join(dp, fn)).st_mode & 0o004 for dp, _, fns in os.walk(site()) for fn in fns)
check("installed files are world-readable for nginx", mode_ok)

print(f"\n{sum(results)}/{len(results)} updater checks passed")
shutil.rmtree(root)
sys.exit(0 if all(results) else 1)
