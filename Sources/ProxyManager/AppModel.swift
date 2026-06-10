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
    }
}
