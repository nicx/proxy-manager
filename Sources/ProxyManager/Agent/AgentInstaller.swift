import Foundation

/// Installs and controls the per-user LaunchAgent that runs Caddy 24/7.
/// Everything happens in the user domain (`gui/$UID`) — no admin prompt, no root.
enum AgentInstaller {
    enum AgentError: LocalizedError {
        case noSeedBinary
        case launchctl(String)
        var errorDescription: String? {
            switch self {
            case .noSeedBinary:
                return "Keine Caddy-Binary gefunden (weder im App-Bundle noch unter Resources/)."
            case .launchctl(let msg):
                return "launchctl-Fehler: \(msg)"
            }
        }
    }

    static var label: String { AppPaths.bundleID }
    private static var serviceTarget: String { "gui/\(getuid())/\(label)" }
    private static var domainTarget: String { "gui/\(getuid())" }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: AppPaths.launchAgentPlist.path)
    }

    /// Copy the bundled Caddy binary into Application Support if it isn't there yet.
    static func seedBinaryIfNeeded() throws {
        try AppPaths.ensureDirectories()
        let fm = FileManager.default
        guard !fm.isExecutableFile(atPath: AppPaths.caddyBinary.path) else { return }
        guard let seed = AppPaths.seedBinary else { throw AgentError.noSeedBinary }
        if fm.fileExists(atPath: AppPaths.caddyBinary.path) {
            try fm.removeItem(at: AppPaths.caddyBinary)
        }
        try fm.copyItem(at: seed, to: AppPaths.caddyBinary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: AppPaths.caddyBinary.path)
    }

    /// Full first-run install: seed binary, write the plist, bootstrap, start.
    static func install(currentConfig: AppConfig) throws {
        try seedBinaryIfNeeded()
        try CaddyController.writeCaddyfile(currentConfig)
        try writePlist()
        try bootstrap()
    }

    static func uninstall() throws {
        try? bootout()
        try? FileManager.default.removeItem(at: AppPaths.launchAgentPlist)
    }

    static func restart() throws {
        let r = Shell.run("/bin/launchctl", ["kickstart", "-k", serviceTarget])
        if !r.ok { throw AgentError.launchctl(r.stderr.isEmpty ? r.stdout : r.stderr) }
    }

    static func stop() throws { try bootout() }
    static func start() throws { try bootstrap() }

    // MARK: - Internals

    private static func bootstrap() throws {
        let r = Shell.run("/bin/launchctl", ["bootstrap", domainTarget, AppPaths.launchAgentPlist.path])
        // bootstrap returns non-zero if already loaded; treat "already bootstrapped" as success.
        if !r.ok && !(r.stderr + r.stdout).lowercased().contains("already") {
            throw AgentError.launchctl(r.stderr.isEmpty ? r.stdout : r.stderr)
        }
    }

    private static func bootout() throws {
        let r = Shell.run("/bin/launchctl", ["bootout", serviceTarget])
        if !r.ok && !(r.stderr + r.stdout).lowercased().contains("no such process") {
            throw AgentError.launchctl(r.stderr.isEmpty ? r.stdout : r.stderr)
        }
    }

    private static func writePlist() throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                AppPaths.caddyBinary.path,
                "run",
                "--config", AppPaths.caddyfile.path,
                "--adapter", "caddyfile",
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardOutPath": AppPaths.logsDir.appendingPathComponent("caddy.out.log").path,
            "StandardErrorPath": AppPaths.logsDir.appendingPathComponent("caddy.err.log").path,
            "EnvironmentVariables": [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: AppPaths.launchAgentPlist, options: .atomic)
    }
}
