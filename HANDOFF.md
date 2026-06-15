# HANDOFF — Kontext für eine neue (Claude-)Session

Dieses Dokument fasst Stand, Entscheidungen und offene Punkte zusammen, damit auf
einem anderen Rechner verlustfrei weitergearbeitet werden kann. **Der Code ist
vollständig in Git** (GitHub `nicx/proxy-manager`); alles Weitere steht hier.

## Schnellstart auf einem neuen Mac
```bash
git clone https://github.com/nicx/proxy-manager.git
cd proxy-manager
Scripts/fetch-caddy.sh     # lädt die (nicht eingecheckte) Caddy-arm64-Binary
Scripts/build-app.sh       # -> build/ProxyManager.app  (ad-hoc signiert)
swift run ProxyManager --selftest   # druckt den generierten Caddyfile (headless)
```
Voraussetzungen: Xcode (macOS 13+ SDK), Apple Silicon. In Xcode: `Package.swift` öffnen.

**Neue Claude-Session briefen:** „Lies `README.md`, `HANDOFF.md` und `git log --oneline`,
bevor du etwas änderst." (Die Chat-Historie der alten Session wird **nicht** automatisch
übertragen — der durable Record sind Git-Historie + diese Datei.)

## Was die App ist
Native macOS-Menüleisten-App (SwiftUI, SwiftPM) als nginx-proxy-manager-Alternative:
steuert eine gebündelte **Caddy**-Engine (Reverse-Proxy + automatisches Let's Encrypt).
Funktionsumfang siehe [README.md](README.md). Eigengebrauch, self-signed/ad-hoc, kein Developer ID.

## Architektur- & Designentscheidungen (nicht umwerfen ohne Grund)
- **Root-frei:** Caddy läuft als User-`LaunchAgent` auf **8080/8443**; Router mappt 80/443.
  24/7 hängt am eingeloggten User → **Auto-Login** nötig.
- **Caddyfile statt JSON-Admin-Config**; nach Änderung `caddy reload` (keine Downtime).
- **pf-Koexistenz (wichtig):** Die optionale Direkt-80/443-Weiterleitung trägt einen
  **benannten Anker** (`com.proxymanager`) **idempotent in `/etc/pf.conf`** ein und lädt
  diese gemeinsame Datei. **Nicht** zum alten Modell (eigenes Voll-Regelwerk via
  `pfctl -f <privat.conf>`) zurück — das überschreibt andere pf-Apps. Das Schwesterprojekt
  **[mailrelay](https://github.com/nicx/mailrelay)** nutzt dasselbe Modell (Anker `mailrelay`, Port 25). Beide koexistieren.
- **Basic-Auth „nur von extern":** per-Host-Flag `basicAuthSkipInternal` + globale
  `internalCIDRs`; CaddyfileBuilder bindet `basic_auth` an `@needauth not remote_ip <intern>`.
  Beruht auf der echten Quell-IP (`remote_ip`) — nur sicher, wenn der Router externe
  Anfragen nicht per SNAT auf eine LAN-IP umschreibt (von extern testen!).
- **Tolerantes Codable** ([Store/CodableDefaults.swift](Sources/ProxyManager/Store/CodableDefaults.swift)): neue Felder **immer** dort
  zu CodingKeys + `init(from:)` ergänzen, sonst scheitert das Laden alter `config.json`.
- **Benachrichtigungen** via lokalem SMTP-Relay (MailRelay, `127.0.0.1:2525`) per `curl`.
  Es werden **keine** per-Request-Fehler (`logger` `http.log.error.*`, z. B. HTTP/2-Idle-
  Timeouts) gemailt — nur Cert/ACME-, Dienst- und Update-Ereignisse.
- **Caddy-Self-Update:** SHA-512 gegen offizielle Release-Checksummen verifiziert (cosign-
  Signaturprüfung bewusst nicht). Icon-Motiv: Schild + Häkchen (`checkmark.shield`).

## Verifizieren (lokal, ohne echtes LE)
- Caddyfile generieren + prüfen: `swift run ProxyManager --selftest > /tmp/Caddyfile && Resources/caddy validate --config /tmp/Caddyfile --adapter caddyfile`
- Funktionale pf-/Auth-/TLS-Checks: Caddy mit `local_certs` + `skip_install_trust` starten (siehe Git-Historie der jeweiligen Commits für die genaue Vorgehensweise).

## Offene Punkte / bekannte Trade-offs
- **24/7** nur mit Auto-Login (Caddy = User-Agent). Alternative wäre root-LaunchDaemon (größerer Umbau; Cert-Status müsste auf TLS-Abfrage umgestellt werden).
- **macOS-Update kann `/etc/pf.conf` zurücksetzen** → pf-Weiterleitung in der App (und in MailRelay) einmal neu „Einrichten". Backups: `/etc/pf.conf.orig.*`.
- **Backend-down (502 / „connection refused")** wird aktuell **nicht** gemailt (nur geloggt), weil unter `http.log.error.*`. Bei Bedarf gezielten Upstream-Alarm nachrüsten.
- Kein DNS-01/Wildcard (HTTP-01 genügt).

## Laufzeitdaten (separat vom Code)
Konfiguration/Zertifikate/Logs liegen unter `~/Library/Application Support/ProxyManager/`.
Für den Umzug einer **laufenden** Instanz: in der App **Export** nutzen (JSON) und auf dem
neuen Mac **Import**; Zertifikate holt Caddy dort automatisch neu (Ports 80/443 müssen
erreichbar sein). Optionales Auto-Backup in einen (z. B. iCloud-)Ordner ist eingebaut.
