# CLAUDE.md — Operating manual for this repo

Native macOS menu-bar app (SwiftUI, SwiftPM) wrapping **Caddy** as an
nginx-proxy-manager alternative (reverse proxy + automatic Let's Encrypt).
Personal use, self-signed/ad-hoc (no Developer ID). Details: [HANDOFF.md](HANDOFF.md), [README.md](README.md).

## Build / run / test
```bash
Scripts/fetch-caddy.sh                 # fetch the (gitignored) Caddy arm64 binary first
swift build                            # compile
Scripts/build-app.sh                   # -> build/ProxyManager.app (ad-hoc signed)
Scripts/make-dmg.sh                    # -> build/ProxyManager.dmg
# Headless check of generated config:
swift run ProxyManager --selftest > /tmp/Caddyfile \
  && Resources/caddy validate --config /tmp/Caddyfile --adapter caddyfile
```
Toolchain: Xcode (macOS 13+ SDK), Apple Silicon. Open `Package.swift` in Xcode.

## Invariants — do NOT change without a clear reason
- **Root-free:** Caddy runs as a user `LaunchAgent` on **8080/8443**; the router maps 80/443.
  Don't switch to a root daemon casually (breaks cert-status file reads, needs rework).
- **pf coexistence:** the optional direct-80/443 redirect registers a **named anchor**
  (`com.proxymanager`) **idempotently in `/etc/pf.conf`** and loads that shared file.
  **Never** revert to loading a private complete ruleset (`pfctl -f <own.conf>`) — it
  flushes other pf apps. The sibling repo **mailrelay** uses the same model (anchor
  `mailrelay`, port 25); keep them compatible.
- **Tolerant Codable:** when adding a field to `ProxyHost`/`AppSettings`/`AppConfig`,
  ALSO add it to [Store/CodableDefaults.swift](Sources/ProxyManager/Store/CodableDefaults.swift) (CodingKeys + `init(from:)`). Otherwise an
  older `config.json`/backup fails to decode and the config is silently lost.
- **Caddyfile is generated** by `CaddyfileBuilder`; apply via `caddy reload` (no downtime).
  Always `caddy validate` generated output before shipping changes.
- **Notifications** must not e-mail per-request errors (`logger` `http.log.error.*` — HTTP/2
  idle timeouts, scanner noise). Only cert/ACME, service-down and update events notify.
- **Caddy self-update** verifies the download via **SHA-512** against the release checksums.

## Conventions
- UI strings are German. In Swift string literals avoid raw ASCII `"` inside German
  quotes — use `„…“` (a stray `"` ends the literal; it has bitten twice).
- Verify changes with the real `caddy` binary (validate / `local_certs` + `skip_install_trust`
  for functional tests) before committing.
- End commit messages with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Commit + push to `main` when work is done (this is the established flow here).
