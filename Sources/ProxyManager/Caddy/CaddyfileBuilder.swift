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
            out += "\n" + hostBlocks(host, internalCIDRs: config.settings.internalCIDRs) + "\n"
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
        lines.append("\t\toutput file \(quote(AppPaths.globalLog.path)) {")
        lines.append("\t\t\troll_size 10MiB")
        lines.append("\t\t\troll_keep 5")
        lines.append("\t\t}")
        lines.append("\t\tformat json")
        lines.append("\t\tlevel \(s.logLevel)")
        lines.append("\t}")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    // MARK: - Per host

    private static func hostBlocks(_ host: ProxyHost, internalCIDRs: [String]) -> String {
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

        // Basic auth (bcrypt hash only). Optionally only for external clients:
        // bind it to a matcher that excludes the configured internal networks.
        if let auth = host.basicAuth, !auth.username.isEmpty, !auth.bcryptHash.isEmpty {
            let cidrs = internalCIDRs
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if host.basicAuthSkipInternal && !cidrs.isEmpty {
                body.append("@needauth not remote_ip \(cidrs.joined(separator: " "))")
                body.append("basic_auth @needauth {")
            } else {
                body.append("basic_auth {")
            }
            body.append("\t\(auth.username) \(auth.bcryptHash)")
            body.append("}")
        }

        // Per-host access log.
        if host.logging {
            body.append("log {")
            body.append("\toutput file \(quote(AppPaths.logFile(for: host).path)) {")
            body.append("\t\troll_size 10MiB")
            body.append("\t\troll_keep 5")
            body.append("\t}")
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
            let rewrite = originRewrite(host)
            if rewrite.isEmpty { return "reverse_proxy \(upstream)" }
            return "reverse_proxy \(upstream) {" + rewrite + "\n}"
        case .https:
            upstream = "https://\(host.upstreamHost):\(host.upstreamPort)"
            // Force HTTP/1.1 when dialing a TLS backend. Over ALPN Caddy would
            // otherwise negotiate HTTP/2, and WebSocket upgrades (Upgrade: websocket)
            // can't ride HTTP/2 — the backend answers 500 on its /…/ws/… endpoints.
            // Symptom: SPA dashboards (e.g. UniFi) "load only halfway" because the
            // static shell + REST work but the live WebSockets die. h1.1 fixes it.
            var transport = ["\t\tversions 1.1"]
            if host.skipTLSVerify { transport.append("\t\ttls_insecure_skip_verify") }
            var block = "reverse_proxy \(upstream) {\n\ttransport http {\n"
                + transport.joined(separator: "\n") + "\n\t}"
            block += originRewrite(host)
            return block + "\n}"
        }
    }

    /// `header_up Origin <upstream-origin>` line when the host opts in, else "".
    /// Sends the backend its *own* origin as the WebSocket Origin so Origin-checking
    /// apps (UniFi OS) accept the upgrade instead of 500-ing. The default port is
    /// omitted to match how browsers form the Origin header.
    private static func originRewrite(_ host: ProxyHost) -> String {
        guard host.rewriteOriginToUpstream else { return "" }
        let scheme = host.upstreamScheme == .https ? "https" : "http"
        let defaultPort = host.upstreamScheme == .https ? 443 : 80
        let origin = host.upstreamPort == defaultPort
            ? "\(scheme)://\(host.upstreamHost)"
            : "\(scheme)://\(host.upstreamHost):\(host.upstreamPort)"
        return "\n\theader_up Origin \(origin)"
    }

    /// Quote a value for the Caddyfile if it contains whitespace.
    private static func quote(_ s: String) -> String {
        s.contains(where: { $0 == " " || $0 == "\t" }) ? "\"\(s)\"" : s
    }
}
