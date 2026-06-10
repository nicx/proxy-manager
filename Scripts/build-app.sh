#!/usr/bin/env bash
# Build ProxyManager.app: compile release, assemble the .app bundle, embed the
# Caddy seed binary, and ad-hoc codesign everything.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/ProxyManager.app"
CADDY_SEED="$ROOT/Resources/caddy"

if [ ! -x "$CADDY_SEED" ]; then
    echo "Caddy seed binary missing. Run Scripts/fetch-caddy.sh first." >&2
    exit 1
fi

echo "==> Building release binary (arm64)…"
swift build -c release --arch arm64

BIN="$(swift build -c release --arch arm64 --show-bin-path)/ProxyManager"
[ -x "$BIN" ] || { echo "Built binary not found at $BIN" >&2; exit 1; }

echo "==> Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ProxyManager"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$CADDY_SEED" "$APP/Contents/Resources/caddy"
chmod +x "$APP/Contents/Resources/caddy"

# Optional app icon: drop Resources/AppIcon.icns to include it.
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

"$ROOT/Scripts/codesign.sh" "$APP"

echo "==> Done: $APP"
