#!/usr/bin/env bash
# Ad-hoc (self-signed) codesign the embedded Caddy binary and the .app bundle.
# For personal use only — first launch still needs right-click → Open (Gatekeeper).
# To get a true one-click experience later, set IDENTITY to a Developer ID and notarize.
set -euo pipefail

APP="${1:-}"
[ -n "$APP" ] || { echo "usage: codesign.sh <path-to.app>" >&2; exit 1; }

IDENTITY="${IDENTITY:--}"   # "-" = ad-hoc

echo "==> Signing embedded caddy"
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/caddy"

echo "==> Signing app bundle"
codesign --force --deep --sign "$IDENTITY" "$APP"

echo "==> Verifying"
codesign --verify --verbose=2 "$APP" || true
