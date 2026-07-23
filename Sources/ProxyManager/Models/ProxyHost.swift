import Foundation

enum UpstreamScheme: String, Codable, CaseIterable, Identifiable {
    case http
    case https
    var id: String { rawValue }
}

/// What a host serves: a reverse proxy to a backend, or a static HTML page
/// served directly by Caddy (no extra webserver process needed).
enum HostTarget: String, Codable, CaseIterable, Identifiable {
    case proxy
    case staticPage
    var id: String { rawValue }
}

/// Credentials for HTTP Basic-Auth on a host. The password is stored only as a
/// bcrypt hash (produced by `caddy hash-password`) — never in clear text.
struct BasicAuth: Codable, Hashable {
    var username: String
    var bcryptHash: String
}

/// One reverse-proxy host: one or more public domains pointing at one upstream,
/// with optional auth, IP access-lists and TLS-verify-skip for self-signed backends.
struct ProxyHost: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var enabled: Bool = true

    /// Public domain names (Caddy provisions a Let's Encrypt cert per name).
    var domains: [String] = []

    /// Reverse proxy (default) or a static HTML page.
    var target: HostTarget = .proxy

    /// HTML/text served when `target == .staticPage`.
    var staticContent: String = ""

    var upstreamScheme: UpstreamScheme = .http
    var upstreamHost: String = "localhost"
    var upstreamPort: Int = 8000

    /// Skip TLS verification toward the backend (needed for self-signed devices like UniFi).
    var skipTLSVerify: Bool = false

    /// Rewrite the `Origin` header sent to the backend to the upstream's own origin.
    /// Some apps (e.g. UniFi OS) validate the WebSocket Origin against their own host
    /// and answer 500 on `/…/ws/…` when it's the proxy's public hostname — the page
    /// then "loads only halfway". REST is unaffected, so only WebSockets break.
    var rewriteOriginToUpstream: Bool = false

    /// Optional Basic-Auth gate.
    var basicAuth: BasicAuth? = nil

    /// If true, Basic-Auth is only required for non-internal source IPs
    /// (see AppSettings.internalCIDRs) — internal/LAN clients skip the prompt.
    var basicAuthSkipInternal: Bool = false

    /// If non-empty, ONLY these IPs/CIDRs may connect; everything else gets 403.
    var allowCIDRs: [String] = []
    /// These IPs/CIDRs are always blocked (evaluated even if allow-list is empty).
    var denyCIDRs: [String] = []

    /// Per-host access log on/off.
    var logging: Bool = true

    var primaryDomain: String { domains.first ?? "" }

    /// Filesystem-safe identifier used for the log file name.
    var logSlug: String {
        let base = primaryDomain.isEmpty ? id.uuidString : primaryDomain
        return base.replacingOccurrences(of: "/", with: "_")
                   .replacingOccurrences(of: ":", with: "_")
    }

    var upstreamDisplay: String {
        "\(upstreamScheme.rawValue)://\(upstreamHost):\(upstreamPort)"
    }

    /// Short description of the target for the host list.
    var targetDisplay: String {
        switch target {
        case .proxy: return upstreamDisplay
        case .staticPage: return "statische Seite"
        }
    }

    /// Basic structural validation; returns a human-readable error or nil.
    func validationError() -> String? {
        let cleaned = domains.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if cleaned.isEmpty { return "Mindestens eine Domain angeben." }
        for d in cleaned where d.contains("/") || d.contains(" ") {
            return "Ungültige Domain: \(d)"
        }
        if target == .proxy {
            if upstreamHost.trimmingCharacters(in: .whitespaces).isEmpty { return "Ziel-Host fehlt." }
            if !(1...65535).contains(upstreamPort) { return "Ziel-Port muss 1–65535 sein." }
        }
        return nil
    }
}
