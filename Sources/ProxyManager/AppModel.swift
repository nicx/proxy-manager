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

    let loginItemAvailable = LoginItem.isAvailable
    private var statusTimer: Timer?

    // Error-notification state.
    private var notifyThrottle: [String: Date] = [:]
    private var logErrorTail = FileTail()
    private var logWatcherPrimed = false
    private var lastCaddyRunning: Bool?

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
        agentInstalled = AgentInstaller.isInstalled
        caddyVersion = CaddyController.version() ?? "nicht installiert"
        // Liveness probe off the main actor would be nicer; it's a short timeout.
        caddyRunning = CaddyController.isRunning()
        if loginItemAvailable { launchAtLogin = LoginItem.isEnabled }
        refreshCerts()
        checkServiceDown()
        checkLogForErrors()
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

    /// Notify once when the service transitions from running to stopped.
    private func checkServiceDown() {
        if agentInstalled, lastCaddyRunning == true, caddyRunning == false {
            notify(subject: "ProxyManager: Dienst gestoppt",
                   body: "Der Caddy-Dienst läuft nicht mehr auf \(ProcessInfo.processInfo.hostName).",
                   key: "service-down")
        }
        lastCaddyRunning = caddyRunning
    }

    /// Watch the global Caddy log for new error-level events (e.g. failed
    /// certificate issuance/renewal) and notify. Skips the backlog on first run.
    private func checkLogForErrors() {
        let lines = logErrorTail.newLines(from: AppPaths.globalLog)
        guard logWatcherPrimed else { logWatcherPrimed = true; return }
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let level = (obj["level"] as? String) ?? ""
            guard level == "error" || level == "fatal" else { continue }
            let logger = (obj["logger"] as? String) ?? "caddy"
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
        guard !domains.isEmpty else { certInfos = [:]; return }
        Task.detached(priority: .utility) {
            var result: [String: CertInfo] = [:]
            for d in domains { result[d] = CertInspector.info(for: d) }
            let snapshot = result
            await MainActor.run { self.certInfos = snapshot }
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
        runAsync("Dienst entfernt.") {
            try AgentInstaller.uninstall()
        } completion: { self.refreshStatus() }
    }

    func restartService() {
        runAsync("Dienst neu gestartet.") {
            try AgentInstaller.restart()
        } completion: { self.refreshStatus() }
    }

    func startService() {
        runAsync("Dienst gestartet.") { try AgentInstaller.start() } completion: { self.refreshStatus() }
    }

    func stopService() {
        runAsync("Dienst gestoppt.") { try AgentInstaller.stop() } completion: { self.refreshStatus() }
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
