# Needle

Your own iPhone music player for the music on your NAS and the songs saved on
your phone, with a real 10-band equalizer, album-color Now Playing, offline
downloads and lock-screen controls.

```
needle/
  server/                 Navidrome (the music server) for the NAS
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
