import Foundation

/// Global proxy settings (everything that is not per-host).
struct AppSettings: Codable, Hashable {
    /// Contact e-mail for the ACME account (recommended by Let's Encrypt).
    var acmeEmail: String = ""

    /// Use the Let's Encrypt staging CA — for testing without hitting rate limits.
    var useStagingCA: Bool = false

    /// Ports Caddy actually binds. The router maps public 80→httpPort, 443→httpsPort.
    var httpPort: Int = 8080
    var httpsPort: Int = 8443

    /// Caddy log level (DEBUG/INFO/WARN/ERROR).
    var logLevel: String = "INFO"

    static let stagingACMEDirectory = "https://acme-staging-v02.api.letsencrypt.org/directory"
}

/// The full document that gets persisted and is the unit of import/export.
struct AppConfig: Codable {
    var settings: AppSettings = AppSettings()
    var hosts: [ProxyHost] = []

    /// Schema version, so future imports can be migrated.
    var version: Int = 1
}
