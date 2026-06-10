#!/usr/bin/env bash
# Download the latest official Caddy macOS arm64 binary into Resources/caddy.
# This is the "seed" binary bundled into the .app; the app can self-update later.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Resources/caddy"

echo "Looking up latest Caddy release…"
TAG=$(curl -fsSL https://api.github.com/repos/caddyserver/caddy/releases/latest \
        | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"v\{0,1\}\([^"]*\)"/\1/')
[ -n "$TAG" ] || { echo "Could not determine latest version" >&2; exit 1; }
echo "Latest Caddy: $TAG"

URL="https://github.com/caddyserver/caddy/releases/download/v${TAG}/caddy_${TAG}_mac_arm64.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $URL"
curl -fsSL "$URL" -o "$TMP/caddy.tar.gz"
tar -xzf "$TMP/caddy.tar.gz" -C "$TMP"

mkdir -p "$ROOT/Resources"
mv "$TMP/caddy" "$DEST"
chmod +x "$DEST"

echo "Installed seed binary -> $DEST"
"$DEST" version
