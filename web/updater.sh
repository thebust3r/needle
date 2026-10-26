#!/bin/sh
# Needle web updater: drop an update zip into the "updates" folder and it's installed within seconds.
#   updates/installed   zips that were installed
#   updates/failed      zips that couldn't be installed (the current version keeps running)
#   updates/backups     the previous versions (last 5 kept)
# Your settings live in your browser, so updating never logs you out.
set -u
APP="${APP:-/app}"
UPD="$APP/updates"
SITE="$APP/site"
mkdir -p "$UPD/installed" "$UPD/failed" "$UPD/backups" "$SITE"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

fail() {   # zip, reason
  mv "$1" "$UPD/failed/$(basename "$1")" 2>/dev/null
  log "FAILED $(basename "$1"): $2. Moved it to updates/failed. Nothing was changed."
}

install_zip() {
  z="$1"
  name=$(basename "$z")
  tmp=$(mktemp -d)
  if ! unzip -q -o "$z" -d "$tmp" >/dev/null 2>&1; then
    rm -rf "$tmp"; fail "$z" "it isn't a working zip file"; return
  fi
  # the web app is the shallowest folder holding both index.html and app.js
  # (works for site/, web/site/, a whole GitHub download, or loose files)
  src=$(find "$tmp" -type f -name index.html | awk '{ n = gsub("/", "/"); print n "\t" $0 }' | sort -n | cut -f 2- |
        while IFS= read -r f; do d=$(dirname "$f"); if [ -f "$d/app.js" ]; then echo "$d"; break; fi; done)
  if [ -z "$src" ]; then
    if [ -n "$(find "$tmp" -type f -name index.html | head -n 1)" ]; then reason="app.js is missing next to index.html"
    else reason="there's no index.html inside, so it isn't a Needle update"; fi
    rm -rf "$tmp"; fail "$z" "$reason"; return
  fi

  stamp=$(date +%Y%m%d-%H%M%S)
  if [ -f "$SITE/index.html" ]; then
    mkdir -p "$UPD/backups/$stamp"
    cp -a "$SITE/." "$UPD/backups/$stamp/"
  fi
  rm -rf "$APP/.site-new" "$APP/.site-old"
  mkdir -p "$APP/.site-new"
  cp -a "$src/." "$APP/.site-new/"
  chmod -R a+rX "$APP/.site-new"
  # swap the new version in all at once
  if mv "$SITE" "$APP/.site-old" && mv "$APP/.site-new" "$SITE"; then
    rm -rf "$APP/.site-old"
  else
    [ -d "$APP/.site-old" ] && [ ! -d "$SITE" ] && mv "$APP/.site-old" "$SITE"
    rm -rf "$tmp"; fail "$z" "couldn't replace the old files"; return
  fi
  rm -rf "$tmp"
  mv "$z" "$UPD/installed/$stamp-$name"
  ver=$(cat "$SITE/version.txt" 2>/dev/null || echo "unknown")
  log "Installed $name (version $ver). Refresh the page to see it."
  # keep the 5 newest backups
  ls -1d "$UPD/backups"/*/ 2>/dev/null | sort | awk '{ a[NR] = $0 } END { for (i = 1; i <= NR - 5; i++) print a[i] }' | while read -r old; do rm -rf "$old"; done
}

log "Needle updater watching $UPD"
[ -f "$SITE/index.html" ] || log "No web app installed yet: drop the Needle web zip into the updates folder."
while :; do
  for z in "$UPD"/*.zip "$UPD"/*.ZIP; do
    [ -f "$z" ] || continue
    # wait until the file has finished copying (size stops changing)
    s1=$(wc -c < "$z"); sleep 2; s2=$(wc -c < "$z" 2>/dev/null || echo 0)
    [ "$s1" = "$s2" ] && [ "$s1" -gt 0 ] || continue
    install_zip "$z"
  done
  [ "${ONCE:-}" = "1" ] && break
  sleep 5
done
