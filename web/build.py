"""Builds docker-compose.yml (with the nginx config and updater built in) and the release zip.
Run: python3 build.py"""
import os, shutil, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
FOLDER = "/volume1/docker/needle-web"


def block(text, indent):
    """Indent text for a YAML block and escape $ for Docker Compose."""
    pad = " " * indent
    return "\n".join((pad + line) if line.strip() else "" for line in text.replace("$", "$$").splitlines())


nginx = open(os.path.join(HERE, "nginx.conf")).read()
updater = open(os.path.join(HERE, "updater.sh")).read()
version = open(os.path.join(HERE, "site", "version.txt")).read().strip()

compose = f"""# Needle web player. Paste this as a new Project in the UGREEN Docker app.
# Folder: {FOLDER}   (it only needs to exist; everything inside is created for you)
# First install: drop the Needle web zip into {FOLDER}/updates
# Updates later: same thing, drop the new zip into updates. No redeploy.
services:
  needle-web:
    image: nginx:alpine
    container_name: needle-web
    restart: unless-stopped
    ports:
      - "8795:80"
    volumes:
      - {FOLDER}:/app:ro
    command:
      - sh
      - -c
      - |
        sed -i 's/^user .*/user root;/' /etc/nginx/nginx.conf
        cat > /etc/nginx/conf.d/default.conf <<'EOF'
{block(nginx, 8)}
        EOF
        exec nginx -g 'daemon off;'
    mem_limit: 64m

  needle-updater:
    image: alpine:3.20
    container_name: needle-updater
    restart: unless-stopped
    volumes:
      - {FOLDER}:/app
    command:
      - sh
      - -c
      - |
        cat > /updater.sh <<'EOF'
{block(updater, 8)}
        EOF
        exec sh /updater.sh
    mem_limit: 32m
"""
open(os.path.join(HERE, "docker-compose.yml"), "w").write(compose)

dist = os.path.join(HERE, "dist")
os.makedirs(dist, exist_ok=True)
zpath = os.path.join(dist, f"Needle-web-v{version}.zip")
with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(os.path.join(HERE, "site")):
        for f in files:
            full = os.path.join(root, f)
            z.write(full, os.path.relpath(full, HERE))
    z.write(os.path.join(HERE, "docker-compose.yml"), "docker-compose.yml")
print("wrote docker-compose.yml and", zpath)
