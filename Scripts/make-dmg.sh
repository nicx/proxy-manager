#!/usr/bin/env bash
# Package ProxyManager.app into a drag-to-Applications DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/ProxyManager.app"
DMG="$ROOT/build/ProxyManager.dmg"
STAGE="$ROOT/build/dmg-stage"

[ -d "$APP" ] || { echo "App not built. Run Scripts/build-app.sh first." >&2; exit 1; }

echo "==> Staging DMG contents…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating DMG…"
hdiutil create -volname "ProxyManager" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG"

rm -rf "$STAGE"
echo "==> Done: $DMG"
