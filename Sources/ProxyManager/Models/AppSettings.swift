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

    // MARK: Error notifications (via a local SMTP relay, e.g. MailRelay)
    /// Send an e-mail when something fails.
    var notifyOnError: Bool = false
    /// Recipient address (configurable).
    var notifyEmail: String = ""
    /// Sender address; empty → "proxymanager@<hostname>".
    var notifyFrom: String = ""
    /// Local relay endpoint (MailRelay default is 127.0.0.1:2525).
    var smtpHost: String = "127.0.0.1"
    var smtpPort: Int = 2525

    // MARK: Automatic backup
    /// Write a timestamped JSON copy of the config to `backupFolder` on every change.
    var backupEnabled: Bool = false
    /// Target folder (e.g. an iCloud-synced directory). Supports a leading "~".
    var backupFolder: String = ""

    static let stagingACMEDirectory = "https://acme-staging-v02.api.letsencrypt.org/directory"
}

/// The full document that gets persisted and is the unit of import/export.
struct AppConfig: Codable {
    var settings: AppSettings = AppSettings()
    var hosts: [ProxyHost] = []

    /// Schema version, so future imports can be migrated.
    var version: Int = 1
}
