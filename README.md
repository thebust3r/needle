# Needle

Your own iPhone music player for the music on your NAS and the songs saved on
your phone, with a real 10-band equalizer, album-color Now Playing, offline
downloads and lock-screen controls.

```
needle/
  server/                 Navidrome (the music server) for the NAS
  web/                    web version of the player (works in Safari)
  ios/                    the iPhone app
  .github/workflows/      builds the app automatically on GitHub
```

---

## 1. Music server on the NAS (Navidrome)

1. Copy the `server` folder to `/volume1/docker/navidrome`.
2. In the UGREEN Docker app, create a new **Project** from that folder.
3. Open `http://192.168.1.168:4533` and create your account. This username
   and password is what the app logs in with.

It reads `/volume1/Music` (read-only, it never changes your files) and checks
for new music every hour.

## 2. Cloudflare (so the app works away from home)

**Point a hostname at Navidrome.** In Cloudflare Zero Trust, open your
tunnel and add a public hostname, for example `music.yourdomain.com`, with
service type **HTTP** and URL `192.168.1.168:4533`.

**Lock it so only the app gets in:**

1. Zero Trust › **Access controls › Service credentials › Service Tokens** ›
   **Create Service Token**. Name it "Needle" and pick a duration. Copy the
   **Client ID** and **Client Secret**. The secret is only shown once.
2. Zero Trust › **Access › Applications** › add a **Self-hosted** app for
   `music.yourdomain.com`.
3. Give it a policy with action **Service Auth** that includes the
   "Needle" service token.

Random visitors now get blocked. The app sends the token with every request.
For Navidrome's web page at home, use `http://192.168.1.168:4533` directly.

## Web version (use this while sideloading is down)

Same look, same equalizer, plus the visualizer and synced lyrics. Runs in
Safari. Needs Navidrome from step 1.

**Install (one time):**

1. In the UGREEN Docker app, create a new **Project** for the folder
   `/volume1/docker/needle-web` and paste in `web/docker-compose.yml`.
   It starts two containers: `needle-web` (the player) and `needle-updater`.
2. Drop the `Needle-web-vX.zip` file into `/volume1/docker/needle-web/updates`
   (the folder appears once the project is running). It installs itself within
   seconds.
3. On your iPhone at home, open `http://192.168.1.168:8795`, sign in with your
   Navidrome account, then **Share › Add to Home Screen**.

**Updating:** drop the new zip into the `updates` folder. That's it.
Installed zips move to `updates/installed`, the previous version is kept in
`updates/backups` (last 5), and a bad zip goes to `updates/failed` without
touching the running version. If music is playing, the app shows a "tap to
refresh" note instead of interrupting the song.

**In the player:**

- **Visualizer:** tap the album art on Now Playing. Tap the style button to
  switch between Warp Ring, Prism, Hyperspace, Melt and Auto; tap the corner
  button for full screen (swipe sideways there to change style). It reacts to
  the music when the EQ is on.
- **Lyrics:** tap the speech-bubble button. Uses lyrics in your music files
  (or `.lrc` files beside them) first, then LRCLIB. Tap a line to jump there.

Limits compared to the real app: with the EQ on, Safari may stop the music
when you lock your phone (turn the EQ off for locked listening), and songs
from your Files app have to be picked again each visit.

**Tests:** `web/tests` has the fake server plus the full test and benchmark
suite (`test_web.py`) and the updater tests (`test_updater.py`).

## Import Spotify playlists

Library › **Import a Spotify Playlist** (web and app). Paste a playlist or album
link, or a list of songs (`Artist - Song`, one per line, or an Exportify CSV).
Needle builds a playlist in Navidrome, in the same order, from the songs you
already have. Missing songs can be fetched with **Just the Songs** (Soulseek via
slskd, saved to `Music/Needle Downloads/<Artist>`) or **Whole Albums** (Lidarr),
and they're slotted into the playlist when they arrive.

It runs as the `needle-helper` container in the web project (same compose file).
Fill in `SLSKD_API_KEY` and `LIDARR_API_KEY` there. The helper updates with the
same zip as the web player.

Limits: Spotify only shares the first 100 songs of a playlist this way (paste the
list for longer ones), playlists must be public, and Soulseek blocks searches
for some artist names.

**Tests:** `web/tests/test_helper.py` (helper against fake Spotify, Navidrome,
slskd, Lidarr and MusicBrainz) and `web/tests/test_import_web.py` (the screen).

## 3. Build the app

GitHub builds it for you (no Mac needed):

1. Put this folder in a **private** GitHub repo.
2. The **Build iPhone app** action runs on every push (or start it from the
   Actions tab).
3. When it finishes, download the **Needle-ipa** file from the run, unzip it,
   and open `Needle.ipa` with **AltStore** on your phone.

AltStore refreshes it every 7 days like your other sideloaded apps.

## 4. First launch

Tap **Connect My Server** and enter:

- Server: `music.yourdomain.com`
- Your Navidrome username and password
- Cloudflare Client ID and Secret

Tap **Test Connection**, then **Continue**.

**Songs saved on your phone:** use Library › On This iPhone › **Import from
Files**, or drop files into Files › On My iPhone › **Needle**. They're picked
up automatically.

## What's in it

- 10-band equalizer you drag directly on a live spectrum of the music,
  13 presets, your own saved presets, preamp, and a distortion guard
- Now Playing that takes its colors from each album cover
- Streams instantly, and buffers the next song so tracks flow together
- Offline downloads (albums or single songs)
- Lock screen, Control Center, AirPlay, Bluetooth, and CarPlay's Now Playing
  screen and steering-wheel buttons
- Shuffle, repeat, a queue you can reorder, favorites, playlists, search
- Plays count toward Navidrome's "most played"

## Notes

- **CarPlay:** it won't get its own CarPlay icon. That needs a permission
  Apple only gives approved developers, and AltStore can't add it. CarPlay's
  Now Playing screen still works.
- **Spotify** songs can't be played by other apps, so they aren't included.
- **Streaming quality** (Settings): Original plays your files untouched.
  320 or 160 kbps saves cellular data. Skipping ahead works best on Original.
