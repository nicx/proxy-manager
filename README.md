# ProxyManager

Eine native macOS-Menüleisten-App als funktionale Alternative zu **nginx-proxy-manager**:
Reverse-Proxy mit **automatischer Let's-Encrypt-Zertifikatsverwaltung**. Die App ist eine
schlanke SwiftUI-Steuerung um eine gebündelte **[Caddy](https://caddyserver.com)**-Engine —
kein Docker, kein Homebrew, **komplett ohne root**.

## Funktionen

- Proxy-Hosts anlegen/bearbeiten/löschen (eine **oder mehrere Domains** → Backend)
- **Statische Seiten** pro Host (eingebauter `file_server`, kein eigenes Backend nötig)
- Automatisches SSL pro Host via Let's Encrypt (HTTP-01) — mit **Status-Anzeige** (Ablauf/Aussteller) und **manueller Erneuerung** je Domain
- Basic-Auth pro Host (Passwort wird als bcrypt-Hash gespeichert)
- IP-/CIDR-Access-Listen (Allow/Deny) pro Host
- Live-Log-Viewer pro Host: **Zugriffe** und **Zertifikats-/ACME-Ereignisse** (Ausstellung/Erneuerung)
- Import/Export der gesamten Konfiguration als JSON
- Automatisches, zeitgestempeltes Backup in einen konfigurierbaren Ordner (z. B. iCloud), letzte 30 Stände
- Caddy-Self-Update (SHA-512-verifiziert gegen die offiziellen Release-Checksummen) mit Rollback
- E-Mail-Benachrichtigung bei Fehlern **und bei verfügbarem Caddy-Update** (über einen lokalen SMTP-Relay wie [MailRelay](https://github.com/nicx/mailrelay), Default `127.0.0.1:2525`)
- Autostart der App beim Login (optional)
- Direkte Ports 80/443 per **pf-Weiterleitung** (optional, einmalig Admin) — für Netze ohne funktionierenden NAT-Hairpin; Caddy bleibt dabei root-frei
- TLS-Verify-Skip für selbstsignierte Backends (z. B. UniFi)

## Architektur

```
   Router:  WAN 80 ─► Mac:8080      WAN 443 ─► Mac:8443
┌─────────────────────────────┐  Admin  ┌──────────────────────────────────┐
│  ProxyManager.app (User)    │  API     │  caddy (User LaunchAgent)          │
│  SwiftUI MenuBarExtra        │ ───────► │  bindet :8080 / :8443              │
│  Caddyfile generieren +      │  :2019   │  Let's Encrypt + Reverse-Proxy     │
│  reload                      │          │  Cert-Storage ~/Library/…          │
└─────────────────────────────┘          └──────────────────────────────────┘
```

Caddy bindet die unprivilegierten Ports **8080/8443**; der Router mappt die öffentlichen
80/443 dorthin. Da Ports < 1024 auf macOS root erfordern, läuft so alles im User-Space.
Caddy läuft als **User-`LaunchAgent`** (`RunAtLoad`/`KeepAlive`) → 24/7, solange der User
angemeldet ist.

Alle Daten unter `~/Library/Application Support/ProxyManager/`:
`Caddyfile`, `config.json`, `bin/caddy`, `caddy/` (Zertifikate), `logs/`,
`sites/` (statische Seiten).

## Bauen

Voraussetzungen: Xcode 15+ (macOS 13+ SDK).

```bash
# 1) Caddy-Seed-Binary holen (einmalig)
Scripts/fetch-caddy.sh

# 2) App bauen + bündeln + ad-hoc signieren
Scripts/build-app.sh        # -> build/ProxyManager.app

# 3) DMG erzeugen (optional)
Scripts/make-dmg.sh         # -> build/ProxyManager.dmg
```

Während der Entwicklung direkt starten: `swift run` (Caddy wird dann aus `Resources/caddy`
oder vom `PATH` als Seed verwendet).

App-Icon (Outline-Pfeile) neu erzeugen: `swift Scripts/make-icon.swift` → `Resources/AppIcon.icns`
(wird von `build-app.sh` automatisch eingebunden).

In Xcode öffnen: `File ▸ Open…` und die `Package.swift` wählen.

## Installation (Eigengebrauch)

1. `ProxyManager.dmg` öffnen, App nach `/Applications` ziehen.
2. **Rechtsklick → Öffnen** beim ersten Start (self-signed → einmaliger Gatekeeper-Bypass).
3. In der App **Status ▸ „Dienst installieren & starten"** klicken (kein Admin-Passwort nötig).
4. Im Router **extern 80 → 8080** und **extern 443 → 8443** weiterleiten.
5. Für 24/7 nach Neustart: **automatische Anmeldung** des Users aktivieren.

> Tipp: Zum Testen in den Einstellungen die **Staging-CA** aktivieren, um die
> Let's-Encrypt-Rate-Limits nicht zu verbrauchen.

## Hinweise

- **Kein Developer ID / keine Notarisierung** (Eigengebrauch). Für echten Doppelklick-Start
  ohne Gatekeeper-Warnung später `IDENTITY` in `Scripts/codesign.sh` auf eine Developer-ID
  setzen und notarisieren.
- **DNS-01/Wildcard** ist bewusst nicht enthalten (HTTP-01 über Port 80 genügt).
- **Interner Zugriff ohne NAT-Hairpin**: Wenn der Router internen Geräten die öffentliche Domain nicht zurück ins LAN spiegelt, in den Einstellungen **„Direkte Ports 80/443 (pf-Weiterleitung)" → Einrichten** (einmalig Admin) und einen **lokalen DNS-Eintrag** setzen (Domain → LAN-IP des Macs). Caddy bleibt auf 8080/8443; pf leitet 80→8080 und 443→8443 um und persistiert über einen kleinen Boot-Daemon (`/Library/LaunchDaemons/com.proxymanager.pf.plist`). Es wird ein **benannter Anker** (`com.proxymanager`) **idempotent in `/etc/pf.conf` eingetragen** (mit einmaligem Backup `/etc/pf.conf.orig.proxymanager`) und dieses gemeinsame Regelwerk geladen — dadurch **koexistiert die Regel mit anderen pf-Apps** (z. B. [MailRelay](https://github.com/nicx/mailrelay) auf Port 25), statt sie zu überschreiben.

## Lizenz

[MIT](LICENSE) © 2026 nicx
