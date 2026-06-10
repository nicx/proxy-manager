import Foundation

struct CertInfo: Equatable {
    enum State: Equatable {
        case valid          // comfortably valid
        case expiringSoon   // within the warning window
        case expired        // past notAfter
        case missing        // no cert in storage yet
        case unknown        // present but couldn't be parsed
    }

    var domain: String
    var notAfter: Date?
    var issuer: String?
    var state: State

    var daysRemaining: Int? {
        guard let notAfter else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: notAfter).day
    }
}

/// Reads Let's Encrypt certificate status from Caddy's on-disk storage and can
/// force re-issuance for a single domain.
///
/// Caddy stores managed certs at:
///   <storage>/certificates/<ca-dir>/<domain>/<domain>.crt
enum CertInspector {
    /// Warn when fewer than this many days remain (Caddy renews ~30 days out).
    static let warnDays = 21

    static func crtURL(for domain: String) -> URL? {
        let certsDir = AppPaths.caddyStorage.appendingPathComponent("certificates")
        guard let en = FileManager.default.enumerator(at: certsDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let target = "\(domain).crt"
        for case let url as URL in en where url.lastPathComponent == target {
            return url
        }
        return nil
    }

    static func info(for domain: String) -> CertInfo {
        guard let crt = crtURL(for: domain) else {
            return CertInfo(domain: domain, notAfter: nil, issuer: nil, state: .missing)
        }
        let r = Shell.run("/usr/bin/openssl", ["x509", "-in", crt.path, "-noout", "-enddate", "-issuer"])
        guard r.ok else {
            return CertInfo(domain: domain, notAfter: nil, issuer: nil, state: .unknown)
        }
        let (notAfter, issuer) = parse(r.stdout)
        let state: CertInfo.State
        if let notAfter {
            if notAfter < Date() {
                state = .expired
            } else {
                let days = Calendar.current.dateComponents([.day], from: Date(), to: notAfter).day ?? 0
                state = days <= warnDays ? .expiringSoon : .valid
            }
        } else {
            state = .unknown
        }
        return CertInfo(domain: domain, notAfter: notAfter, issuer: issuer, state: state)
    }

    /// Force re-issuance: delete the stored cert for this domain and restart
    /// Caddy so it obtains a fresh one on startup (clears the in-memory cache).
    /// Causes a brief restart of the proxy and uses a Let's Encrypt issuance.
    static func forceRenew(domain: String) throws {
        if let crt = crtURL(for: domain) {
            try FileManager.default.removeItem(at: crt.deletingLastPathComponent())
        }
        try AgentInstaller.restart()
    }

    // MARK: - Parsing

    private static func parse(_ out: String) -> (Date?, String?) {
        var date: Date?
        var issuer: String?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("notAfter=") {
                date = parseDate(String(line.dropFirst("notAfter=".count)))
            } else if line.hasPrefix("issuer=") {
                let raw = String(line.dropFirst("issuer=".count))
                issuer = extractCN(raw) ?? raw.trimmingCharacters(in: .whitespaces)
            }
        }
        return (date, issuer)
    }

    private static func parseDate(_ raw: String) -> Date? {
        // openssl prints e.g. "Sep  4 12:00:00 2026 GMT" (day may be space-padded).
        let normalized = raw.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM d HH:mm:ss yyyy zzz"
        return df.date(from: normalized)
    }

    private static func extractCN(_ s: String) -> String? {
        // issuer like "C=US, O=Let's Encrypt, CN=R3" or "/C=US/O=…/CN=R3"
        let parts = s.replacingOccurrences(of: "/", with: ",").split(separator: ",")
        for p in parts {
            let t = p.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("CN=") { return String(t.dropFirst(3)) }
        }
        return nil
    }
}
