import Foundation
import Combine
import SwiftUI

/// Single source of truth for the UI. Owns the config, persists changes, and
/// drives Caddy (write Caddyfile + reload) and the LaunchAgent lifecycle.
@MainActor
final class AppModel: ObservableObject {
    @Published var config: AppConfig
    @Published var caddyRunning: Bool = false
    @Published var agentInstalled: Bool = false
    @Published var caddyVersion: String = "—"
    @Published var lastError: String?
    @Published var statusMessage: String?
    @Published var busy: Bool = false
    @Published var launchAtLogin: Bool = false
    /// SSL certificate status keyed by domain.
    @Published var certInfos: [String: CertInfo] = [:]
    /// Newer Caddy version available (nil if up to date / unknown).
    @Published var updateAvailable: String?
    /// Whether the pf 80/443 redirect is installed and actually live.
    @Published var portForwardingInstalled: Bool = false
    /// Stale daemon plist but the anchor is gone from /etc/pf.conf (e.g. after a
    /// macOS update) — the redirect is dead and needs a one-click repair.
    @Published var portForwardingNeedsRepair: Bool = false

    private var lastUpdateCheck: Date?

    let loginItemAvailable = LoginItem.isAvailable
    private var statusTimer: Timer?

    // Error-notification state.
    private var notifyThrottle: [String: Date] = [:]
    private var logErrorTail = FileTail()
    private var logWatcherPrimed = false
    /// Consecutive "not running" liveness readings — used to debounce a single
    /// slow/timed-out admin-API probe so it can't fire a false outage alert.
    private var consecutiveDownReadings = 0
    /// Until this time, a detected stop is treated as user-initiated (no alert).
    private var suppressDownUntil: Date?
    /// True once we've e-mailed about an *unexpected* outage (so we can send a recovery mail).
    private var notifiedUnexpectedDown = false
    /// True once we've e-mailed that the pf redirect broke (anchor gone after a
    /// macOS update) — so we alert once and send a recovery mail when repaired.
    private var notifiedPfNeedsRepair = false

    init() {
        self.config = HostStore.load()
        refreshStatus()
        let t = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t
        syncOnLaunch()
    }

    /// Regenerate the Caddyfile from the stored config on launch and reload if
    /// Caddy is running. Ensures config changes shipped with an app update
    /// (e.g. the global TLS/ACME log) take effect without manual action.
    private func syncOnLaunch() {
        guard agentInstalled else { return }
        let cfg = config
        Task.detached {
            try? CaddyController.writeCaddyfile(cfg)
            if CaddyController.isRunning() {
                try? CaddyController.apply(cfg)
            }
        }
    }

    // MARK: - Status

    func refreshStatus() {
        // The two expensive probes must not run on the main thread: `version()`
        // spawns a subprocess and `isRunning()` blocks on a semaphore up to 1.5s.
        // Run every 5s on the main thread they froze the UI. Probe off-main, apply back.
        Task.detached(priority: .utility) {
            let version = CaddyController.version() ?? "nicht installiert"
            let running = CaddyController.isRunning()
            await MainActor.run { self.applyStatus(version: version, running: running) }
        }
    }

    /// Apply probed status on the main actor. Assign only when a value actually
    /// changed — an unconditional write to an @Published fires objectWillChange
    /// even for an identical value, and with MenuBarExtra's `.window` style that
    /// rebuilds the whole menu view every 5s and accumulates view storage without
    /// bound (observed: ~1.9M leaked Label views, multi-GB footprint over days).
    private func applyStatus(version: String, running: Bool) {
        let installed = AgentInstaller.isInstalled
        let pfInstalled = PortForwarder.isInstalled
        let pfNeedsRepair = PortForwarder.needsRepair
        if agentInstalled != installed { agentInstalled = installed }
        if caddyVersion != version { caddyVersion = version }
        if caddyRunning != running { caddyRunning = running }
        if loginItemAvailable {
            let enabled = LoginItem.isEnabled
            if launchAtLogin != enabled { launchAtLogin = enabled }
        }
        if portForwardingInstalled != pfInstalled { portForwardingInstalled = pfInstalled }
        if portForwardingNeedsRepair != pfNeedsRepair { portForwardingNeedsRepair = pfNeedsRepair }
        refreshCerts()
        checkServiceDown()
        checkPortForwardingRepair()
        checkLogForErrors()
        maybeCheckForUpdate()
    }

    // MARK: - Caddy update check

    /// Throttle the network update check to roughly once a day.
    private func maybeCheckForUpdate() {
        let now = Date()
        if let last = lastUpdateCheck, now.timeIntervalSince(last) < 86_400 { return }
        lastUpdateCheck = now
        checkForUpdate()
    }

    /// Compare the installed Caddy with the latest GitHub release; update the
    /// `updateAvailable` flag and e-mail once per new version (if enabled).
    func checkForUpdate() {
        guard let installed = Self.parseVersion(caddyVersion) else { updateAvailable = nil; return }
        Task {
            guard let release = try? await CaddyUpdater.fetchLatest() else { return }
            let latest = release.version
            guard Self.isNewer(latest, than: installed) else {
                self.updateAvailable = nil
                return
            }
            self.updateAvailable = latest
            guard self.config.settings.notifyOnUpdate,
                  !self.config.settings.notifyEmail.trimmingCharacters(in: .whitespaces).isEmpty,
                  self.config.lastNotifiedUpdate != latest else { return }
            let settings = self.config.settings
            let body = "Eine neue Caddy-Version ist verfügbar: \(latest)\nInstalliert: \(installed)\n\nIn ProxyManager unter „Status“ aktualisieren."
            Task.detached {
                try? Notifier.send(subject: "ProxyManager: Caddy-Update \(latest) verfügbar",
                                   body: body, settings: settings)
            }
            self.config.lastNotifiedUpdate = latest
            try? HostStore.save(self.config)
        }
    }

    /// Parse a Caddy version string ("v2.11.4 h1:…") to "2.11.4", or nil.
    static func parseVersion(_ s: String) -> String? {
        let token = s.split(separator: " ").first.map(String.init) ?? s
        let v = token.hasPrefix("v") ? String(token.dropFirst()) : token
        return v.first?.isNumber == true ? v : nil
    }

    /// True if semver `a` is strictly greater than `b`.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Error notifications

    /// Send an error e-mail if enabled, deduplicated per `key` for 5 minutes.
    private func notify(subject: String, body: String, key: String) {
        guard config.settings.notifyOnError,
              !config.settings.notifyEmail.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let now = Date()
        if let last = notifyThrottle[key], now.timeIntervalSince(last) < 300 { return }
        notifyThrottle[key] = now
        let settings = config.settings
        Task.detached { try? Notifier.send(subject: subject, body: body, settings: settings) }
    }

    /// Alert once when the pf 80/443 redirect breaks (daemon plist survives but the
    /// anchor vanished from /etc/pf.conf, typically after a macOS update reset it) —
    /// the site is then unreachable on 80/443 while DNS still resolves. Send a
    /// recovery mail once repaired. The alert mail itself goes out via the local
    /// relay on 127.0.0.1:2525, which is independent of this inbound redirect.
    private func checkPortForwardingRepair() {
        let host = ProcessInfo.processInfo.hostName
        if portForwardingNeedsRepair {
            if !notifiedPfNeedsRepair {
                notify(subject: "ProxyManager: Port-Weiterleitung inaktiv",
                       body: "Die pf-Weiterleitung 80/443 auf \(host) ist nicht mehr aktiv "
                           + "(Anker fehlt in /etc/pf.conf — meist nach einem macOS-Update). "
                           + "Die Seiten sind von außen nicht erreichbar, obwohl DNS auflöst. "
                           + "Beheben: ProxyManager, Einstellungen, Abschnitt Direkte Ports 80/443, Knopf Reparieren.",
                       key: "pf-needs-repair")
                notifiedPfNeedsRepair = true
            }
        } else if notifiedPfNeedsRepair {
            notify(subject: "ProxyManager: Port-Weiterleitung wieder aktiv",
                   body: "Die pf-Weiterleitung 80/443 auf \(host) ist wieder eingerichtet.",
                   key: "pf-repaired")
            notifiedPfNeedsRepair = false
        }
    }

    /// Mark a user-initiated start/stop/restart so the resulting state change
    /// isn't reported as an unexpected outage. Time-boxed so a never-observed
    /// transition can't permanently mute future real outages.
    private func markUserServiceAction() {
        suppressDownUntil = Date().addingTimeInterval(30)
    }

    /// Alert on *unexpected* stop (running→stopped, not user-initiated) and on
    /// recovery (stopped→running after such an alert).
    private func checkServiceDown() {
        let host = ProcessInfo.processInfo.hostName
        guard agentInstalled else { consecutiveDownReadings = 0; return }

        if caddyRunning {
            if notifiedUnexpectedDown {
                notify(subject: "ProxyManager: Dienst wieder online",
                       body: "Der Caddy-Dienst läuft wieder auf \(host).",
                       key: "service-up")
                notifiedUnexpectedDown = false
            }
            consecutiveDownReadings = 0
        } else {
            consecutiveDownReadings += 1
            let userInitiated = suppressDownUntil.map { Date() < $0 } ?? false
            // Require two consecutive "down" readings (~10s) before alerting: the
            // liveness check is a 1.5s admin-API probe, and a single slow/timed-out
            // response must not be reported as an outage (Caddy is often still up).
            if consecutiveDownReadings >= 2, !userInitiated, !notifiedUnexpectedDown {
                notify(subject: "ProxyManager: Dienst unerwartet gestoppt",
                       body: "Der Caddy-Dienst läuft nicht mehr auf \(host) (kein manueller Stopp).",
                       key: "service-down")
                notifiedUnexpectedDown = true
            }
        }
    }

    /// Watch the global Caddy log for new error-level events (e.g. failed
    /// certificate issuance/renewal) and notify. Skips the backlog on first run.
    private func checkLogForErrors() {
        guard logWatcherPrimed else {
            // Seek to the current end once — never read the (possibly huge) backlog.
            logErrorTail.primeToEnd(from: AppPaths.globalLog)
            logWatcherPrimed = true
            return
        }
        let lines = logErrorTail.newLines(from: AppPaths.globalLog)
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let level = (obj["level"] as? String) ?? ""
            guard level == "error" || level == "fatal" else { continue }
            let logger = (obj["logger"] as? String) ?? "caddy"
            // Per-request HTTP errors (HTTP/2 idle timeouts like "no recent network
            // activity", client disconnects, internet-scanner probes, transient
            // upstream hiccups) are routine noise on a public proxy — keep them in
            // the log/viewer but don't e-mail. Cert/ACME and service errors use
            // other loggers (tls.*, admin, …) and still trigger a notification.
            if logger.hasPrefix("http.log.error") { continue }
            let msg = (obj["msg"] as? String) ?? ""
            var body = "Logger: \(logger)\nMeldung: \(msg)"
            if let id = obj["identifier"] as? String { body += "\nDomain: \(id)" }
            if let err = obj["error"] as? String { body += "\nDetails: \(err)" }
            notify(subject: "ProxyManager: Caddy-Fehler", body: body, key: "log:\(logger):\(msg)")
        }
    }

    /// Send a test e-mail using the given (possibly unsaved) settings.
    func sendTestMail(_ settings: AppSettings) {
        busy = true
        lastError = nil
        statusMessage = "Sende Testmail…"
        Task.detached {
            do {
                try Notifier.send(subject: "ProxyManager Testmail",
                                  body: "Dies ist eine Testnachricht von ProxyManager. Wenn du sie erhältst, funktioniert der Mailversand.",
                                  settings: settings)
                await MainActor.run { self.statusMessage = "Testmail gesendet."; self.busy = false }
            } catch {
                await MainActor.run { self.report(error); self.busy = false }
            }
        }
    }

    /// Re-read certificate status for every configured domain (off the main thread).
    func refreshCerts() {
        let domains = config.hosts.flatMap { $0.domains }
        guard !domains.isEmpty else { if !certInfos.isEmpty { certInfos = [:] }; return }
        Task.detached(priority: .utility) {
            var result: [String: CertInfo] = [:]
            for d in domains { result[d] = CertInspector.info(for: d) }
            let snapshot = result
            // Only publish on real change (see applyStatus): avoids a needless
            // objectWillChange every 5s that would rebuild the menu view.
            await MainActor.run { if snapshot != self.certInfos { self.certInfos = snapshot } }
        }
    }

    /// Manually force re-issuance of a domain's certificate. Briefly restarts Caddy.
    func renewCert(domain: String) {
        busy = true
        lastError = nil
        statusMessage = "Erneuere Zertifikat für \(domain)…"
        Task.detached {
            do {
                try CertInspector.forceRenew(domain: domain)
            } catch {
                await MainActor.run { self.report(error); self.busy = false }
                return
            }
            // Give Caddy a few seconds to restart and obtain the new cert.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                self.busy = false
                self.statusMessage = "Erneuerung angestoßen für \(domain)."
                self.refreshStatus()
            }
        }
    }

    /// Enable/disable launching the ProxyManager app at login.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            launchAtLogin = LoginItem.isEnabled
            statusMessage = enabled ? "Autostart aktiviert." : "Autostart deaktiviert."
        } catch {
            report(error)
            launchAtLogin = LoginItem.isEnabled
        }
    }

    // MARK: - Persistence + apply

    private func persist() {
        do { try HostStore.save(config) }
        catch { report(error) }
        writeBackupIfEnabled()
    }

    /// Write an automatic backup snapshot after a config change, if enabled.
    private func writeBackupIfEnabled() {
        guard config.settings.backupEnabled else { return }
        let folder = config.settings.backupFolder.trimmingCharacters(in: .whitespaces)
        guard !folder.isEmpty else { return }
        let cfg = config
        Task.detached {
            do { try BackupManager.write(cfg, toFolder: folder) }
            catch { await MainActor.run { self.lastError = "Backup fehlgeschlagen: \(error.localizedDescription)" } }
        }
    }

    /// Manually trigger a backup using the given (possibly unsaved) settings.
    func backupNow(_ settings: AppSettings) {
        let folder = settings.backupFolder.trimmingCharacters(in: .whitespaces)
        guard !folder.isEmpty else { report(SimpleError("Kein Backup-Ordner gewählt.")); return }
        var cfg = config
        cfg.settings = settings
        busy = true
        Task.detached {
            do {
                try BackupManager.write(cfg, toFolder: folder)
                await MainActor.run { self.statusMessage = "Backup gespeichert."; self.busy = false }
            } catch {
                await MainActor.run { self.report(error); self.busy = false }
            }
        }
    }

    /// Save config, regenerate the Caddyfile and reload Caddy (no downtime).
    func applyChanges() {
        persist()
        guard agentInstalled else {
            statusMessage = "Dienst noch nicht installiert — bitte zuerst einrichten."
            return
        }
        runAsync("Konfiguration übernommen.") {
            try CaddyController.apply(self.config)
        }
    }

    // MARK: - Host CRUD

    func upsert(_ host: ProxyHost) {
        if let idx = config.hosts.firstIndex(where: { $0.id == host.id }) {
            config.hosts[idx] = host
        } else {
            config.hosts.append(host)
        }
        applyChanges()
    }

    func delete(_ host: ProxyHost) {
        config.hosts.removeAll { $0.id == host.id }
        applyChanges()
    }

    func toggle(_ host: ProxyHost) {
        guard let idx = config.hosts.firstIndex(where: { $0.id == host.id }) else { return }
        config.hosts[idx].enabled.toggle()
        applyChanges()
    }

    // MARK: - Settings

    func saveSettings(_ settings: AppSettings) {
        config.settings = settings
        applyChanges()
    }

    /// Persist just the backup folder immediately (no Caddy reload needed).
    /// Used by the folder picker so the choice survives even if the menu closes.
    func setBackupFolder(_ path: String) {
        config.settings.backupFolder = path
        do { try HostStore.save(config) } catch { report(error) }
    }

    // MARK: - Agent lifecycle

    func installService() {
        runAsync("Dienst installiert und gestartet.") {
            try AgentInstaller.install(currentConfig: self.config)
        } completion: { self.refreshStatus() }
    }

    func uninstallService() {
        markUserServiceAction()
        runAsync("Dienst entfernt.") {
            try AgentInstaller.uninstall()
        } completion: { self.refreshStatus() }
    }

    func restartService() {
        markUserServiceAction()
        runAsync("Dienst neu gestartet.") {
            try AgentInstaller.restart()
        } completion: { self.refreshStatus() }
    }

    func startService() {
        markUserServiceAction()
        runAsync("Dienst gestartet.") { try AgentInstaller.start() } completion: { self.refreshStatus() }
    }

    func stopService() {
        markUserServiceAction()
        runAsync("Dienst gestoppt.") { try AgentInstaller.stop() } completion: { self.refreshStatus() }
    }

    // MARK: - Privileged port forwarding (pf)

    func installPortForwarding() {
        let http = config.settings.httpPort
        let https = config.settings.httpsPort
        busy = true; lastError = nil
        statusMessage = "Richte Port-Weiterleitung ein…"
        Task.detached {
            do {
                try PortForwarder.install(httpPort: http, httpsPort: https)
                await MainActor.run {
                    self.statusMessage = "Port-Weiterleitung aktiv (80→\(http), 443→\(https))."
                    self.busy = false; self.refreshStatus()
                }
            } catch {
                await MainActor.run { self.report(error); self.busy = false; self.refreshStatus() }
            }
        }
    }

    func removePortForwarding() {
        busy = true; lastError = nil
        statusMessage = "Entferne Port-Weiterleitung…"
        Task.detached {
            do {
                try PortForwarder.uninstall()
                await MainActor.run {
                    self.statusMessage = "Port-Weiterleitung entfernt."
                    self.busy = false; self.refreshStatus()
                }
            } catch {
                await MainActor.run { self.report(error); self.busy = false; self.refreshStatus() }
            }
        }
    }

    // MARK: - Import / Export

    func export(to url: URL) {
        do { try ConfigIO.export(config, to: url); statusMessage = "Exportiert." }
        catch { report(error) }
    }

    func importConfig(from url: URL) {
        do {
            config = try ConfigIO.import(from: url)
            applyChanges()
            statusMessage = "Importiert."
        } catch { report(error) }
    }

    // MARK: - Caddy update

    func updateCaddy() {
        busy = true
        statusMessage = "Suche nach Caddy-Update…"
        Task {
            do {
                let release = try await CaddyUpdater.fetchLatest()
                statusMessage = "Lade Caddy \(release.version)…"
                try await CaddyUpdater.install(release)
                statusMessage = "Caddy auf \(release.version) aktualisiert."
                updateAvailable = nil
            } catch {
                report(error)
            }
            busy = false
            refreshStatus()
        }
    }

    // MARK: - Helpers

    private func runAsync(_ success: String,
                          _ work: @escaping () throws -> Void,
                          completion: (() -> Void)? = nil) {
        busy = true
        lastError = nil
        Task.detached {
            do {
                try work()
                await MainActor.run {
                    self.statusMessage = success
                    self.busy = false
                    completion?()
                }
            } catch {
                await MainActor.run {
                    self.report(error)
                    self.busy = false
                    completion?()
                }
            }
        }
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        statusMessage = nil
        notify(subject: "ProxyManager: Fehler",
               body: error.localizedDescription,
               key: "report:\(error.localizedDescription)")
    }
}
