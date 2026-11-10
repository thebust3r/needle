"""Stand-in for yt-dlp in the helper tests: canned YouTube search results, and a real (tiny) audio file as the download."""
import json, os, subprocess, sys

args = sys.argv[1:]
LOG = os.environ.get("FAKE_YT_LOG")
if LOG:
    with open(LOG, "a") as f:
        f.write(json.dumps(args) + "\n")

RESULTS = {
    "nobody known obscure song": [
        {"id": "cov1", "title": "Obscure Song (cover by someone)", "channel": "Some Kid", "duration": 180},
        {"id": "mv1", "title": "Nobody Known - Obscure Song (Official Music Video)", "channel": "NobodyKnownVEVO", "duration": 182},
        {"id": "top1", "title": "Obscure Song", "channel": "Nobody Known - Topic", "duration": 181},
        {"id": "slow1", "title": "Nobody Known - Obscure Song (slowed + reverb)", "channel": "chill", "duration": 230},
    ],
    "m83 wait": [
        {"id": "wait1", "title": "Wait", "channel": "M83 - Topic", "duration": 343},
    ],
}

search = next((a for a in args if a.startswith("ytsearch")), None)
if search:
    q = search.split(":", 1)[1].lower()
    for e in RESULTS.get(q, []):
        print(json.dumps(e))
    sys.exit(0)

url = next(a for a in args if a.startswith("https://"))
vid = url.rsplit("=", 1)[-1]
out = args[args.index("-o") + 1].replace("%(id)s", vid).replace("%(ext)s", "webm")
for p in (10, 55, 100):
    print(f"[download] {p:5.1f}% of 3.10MiB at 1.00MiB/s ETA 00:01", flush=True)
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                "-c:a", "libopus", "-b:a", "64k", out], check=True)
