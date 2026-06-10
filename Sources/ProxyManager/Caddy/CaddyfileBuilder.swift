import Foundation

/// Turns the app configuration into a Caddyfile.
///
/// Notes on the high-port setup (Caddy binds 8080/8443, router maps 80/443):
/// we set `auto_https disable_redirects` globally and emit an *explicit*
/// `http://` redirect block per host that points at the bare `https://{host}`
/// (no port). Otherwise Caddy's automatic redirect would put `:8443` into the
/// Location header, which is wrong for external clients.
enum CaddyfileBuilder {
    static func build(_ config: AppConfig) -> String {
        var out = globalBlock(config.settings)
        out += "\n"
        for host in config.hosts where host.enabled && host.validationError() == nil {
            out += "\n" + hostBlocks(host) + "\n"
        }
        return out
    }

    // MARK: - Global

    private static func globalBlock(_ s: AppSettings) -> String {
        var lines: [String] = ["{"]
        let email = s.acmeEmail.trimmingCharacters(in: .whitespaces)
        if !email.isEmpty { lines.append("\temail \(email)") }
        lines.append("\thttp_port \(s.httpPort)")
        lines.append("\thttps_port \(s.httpsPort)")
        lines.append("\tauto_https disable_redirects")
        if s.useStagingCA {
            lines.append("\tacme_ca \(AppSettings.stagingACMEDirectory)")
        }
        lines.append("\tadmin 127.0.0.1:2019")
        lines.append("\tstorage file_system \(quote(AppPaths.caddyStorage.path))")
        // Default logger → JSON file. This captures TLS/ACME events (logger
        // names "tls.*") so the app can show certificate issuance/renewal.
        lines.append("\tlog {")
        lines.append("\t\toutput file \(quote(AppPaths.globalLog.path))")
        lines.append("\t\tformat json")
        lines.append("\t\tlevel \(s.logLevel)")
        lines.append("\t}")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    // MARK: - Per host

    private static func hostBlocks(_ host: ProxyHost) -> String {
        let domains = host.domains
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 1) Explicit HTTP→HTTPS redirect to the bare host (no :8443).
        let httpNames = domains.map { "http://\($0)" }.joined(separator: ", ")
        var out = "\(httpNames) {\n\tredir https://{host}{uri} permanent\n}\n\n"

        // 2) The HTTPS site.
        let httpsNames = domains.joined(separator: ", ")
        var body: [String] = []

        // Access list: deny anything not explicitly allowed, plus explicit denies.
        if !host.allowCIDRs.isEmpty {
            let allowed = host.allowCIDRs.joined(separator: " ")
            body.append("@notAllowed not remote_ip \(allowed)")
            body.append("respond @notAllowed 403")
        }
        if !host.denyCIDRs.isEmpty {
            let denied = host.denyCIDRs.joined(separator: " ")
            body.append("@denied remote_ip \(denied)")
            body.append("respond @denied 403")
        }

        // Basic auth (bcrypt hash only).
        if let auth = host.basicAuth, !auth.username.isEmpty, !auth.bcryptHash.isEmpty {
            body.append("basic_auth {")
            body.append("\t\(auth.username) \(auth.bcryptHash)")
            body.append("}")
        }

        // Per-host access log.
        if host.logging {
            body.append("log {")
            body.append("\toutput file \(quote(AppPaths.logFile(for: host).path))")
            body.append("\tformat json")
            body.append("}")
        }

        // Target: reverse proxy to a backend, or serve a static page.
        switch host.target {
        case .proxy:
            body.append(reverseProxy(host))
        case .staticPage:
            body.append("root * \(quote(AppPaths.siteDir(for: host).path))")
            body.append("file_server")
        }

        out += "\(httpsNames) {\n"
        out += body.map { "\t" + $0.replacingOccurrences(of: "\n", with: "\n\t") }
                   .joined(separator: "\n")
        out += "\n}"
        return out
    }

    private static func reverseProxy(_ host: ProxyHost) -> String {
        let upstream: String
        switch host.upstreamScheme {
        case .http:
            upstream = "\(host.upstreamHost):\(host.upstreamPort)"
            return "reverse_proxy \(upstream)"
        case .https:
            upstream = "https://\(host.upstreamHost):\(host.upstreamPort)"
            if host.skipTLSVerify {
                return "reverse_proxy \(upstream) {\n\ttransport http {\n\t\ttls_insecure_skip_verify\n\t}\n}"
            }
            return "reverse_proxy \(upstream)"
        }
    }

    /// Quote a value for the Caddyfile if it contains whitespace.
    private static func quote(_ s: String) -> String {
        s.contains(where: { $0 == " " || $0 == "\t" }) ? "\"\(s)\"" : s
    }
}
