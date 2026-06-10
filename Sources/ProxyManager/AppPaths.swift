import Foundation

/// Central location for every on-disk path the app uses. Everything lives under
/// `~/Library/Application Support/ProxyManager/` so it is user-owned and survives
/// reboots — no root, no privileged locations.
enum AppPaths {
    static let bundleID = "com.proxymanager.caddy"

    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ProxyManager", isDirectory: true)
    }

    /// Directory holding the working `caddy` binary (replaced by self-update).
    static var binDir: URL { appSupport.appendingPathComponent("bin", isDirectory: true) }
    static var caddyBinary: URL { binDir.appendingPathComponent("caddy") }
    static var caddyBackup: URL { binDir.appendingPathComponent("caddy.bak") }

    /// Caddy's certificate/ACME storage.
    static var caddyStorage: URL { appSupport.appendingPathComponent("caddy", isDirectory: true) }

    /// Per-host JSON access logs.
    static var logsDir: URL { appSupport.appendingPathComponent("logs", isDirectory: true) }

    /// Caddy's default logger (TLS/ACME/runtime events) as JSON.
    static var globalLog: URL { logsDir.appendingPathComponent("caddy.json") }

    static var caddyfile: URL { appSupport.appendingPathComponent("Caddyfile") }

    /// Document roots for hosts that serve a static page.
    static var sitesDir: URL { appSupport.appendingPathComponent("sites", isDirectory: true) }
    static func siteDir(for host: ProxyHost) -> URL {
        sitesDir.appendingPathComponent(host.id.uuidString, isDirectory: true)
    }
    static func siteIndex(for host: ProxyHost) -> URL {
        siteDir(for: host).appendingPathComponent("index.html")
    }

    /// Persisted app configuration (host list + settings).
    static var configStore: URL { appSupport.appendingPathComponent("config.json") }

    static var launchAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }
    static var launchAgentPlist: URL {
        launchAgentsDir.appendingPathComponent("\(bundleID).plist")
    }

    /// The Caddy binary shipped inside the .app bundle (the "seed"), copied to
    /// `binDir` on first launch. Falls back to a few dev locations when running
    /// via `swift run` outside a packaged bundle.
    static var seedBinary: URL? {
        if let inBundle = Bundle.main.url(forResource: "caddy", withExtension: nil) {
            return inBundle
        }
        // Dev fallbacks: Resources/caddy next to the package, or on PATH.
        let candidates = [
            URL(fileURLWithPath: "Resources/caddy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/caddy"),
            URL(fileURLWithPath: "/usr/local/bin/caddy"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var logLevel: String { "INFO" }

    /// Create all directories the app needs. Safe to call repeatedly.
    static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [appSupport, binDir, caddyStorage, logsDir, launchAgentsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func logFile(for host: ProxyHost) -> URL {
        logsDir.appendingPathComponent("\(host.logSlug).json")
    }
}
