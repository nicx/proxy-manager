import Foundation

/// Drives the bundled `caddy` binary: write the Caddyfile, validate, reload
/// without downtime, hash passwords, query version/health.
enum CaddyController {
    enum CaddyError: LocalizedError {
        case binaryMissing
        case command(String)
        var errorDescription: String? {
            switch self {
            case .binaryMissing: return "Caddy-Binary nicht gefunden. Bitte Dienst neu installieren."
            case .command(let msg): return msg
            }
        }
    }

    static var binaryPath: String { AppPaths.caddyBinary.path }

    private static func ensureBinary() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw CaddyError.binaryMissing
        }
    }

    /// Write the Caddyfile for the given config to disk (plus static site files).
    static func writeCaddyfile(_ config: AppConfig) throws {
        try AppPaths.ensureDirectories()
        try writeStaticSites(config)
        let text = CaddyfileBuilder.build(config)
        try text.write(to: AppPaths.caddyfile, atomically: true, encoding: .utf8)
    }

    /// Write an index.html for every static-page host, and remove site
    /// directories for hosts that no longer exist or are no longer static.
    static func writeStaticSites(_ config: AppConfig) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: AppPaths.sitesDir, withIntermediateDirectories: true)

        var keep = Set<String>()
        for host in config.hosts where host.target == .staticPage {
            let dir = AppPaths.siteDir(for: host)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let content = host.staticContent.isEmpty ? defaultStaticPage(host) : host.staticContent
            try content.write(to: AppPaths.siteIndex(for: host), atomically: true, encoding: .utf8)
            keep.insert(host.id.uuidString)
        }

        if let entries = try? fm.contentsOfDirectory(at: AppPaths.sitesDir, includingPropertiesForKeys: nil) {
            for url in entries where !keep.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
        }
    }

    private static func defaultStaticPage(_ host: ProxyHost) -> String {
        let title = host.primaryDomain.isEmpty ? "ProxyManager" : host.primaryDomain
        return "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(title)</title></head>"
             + "<body><h1>\(title)</h1><p>Diese Seite wird von ProxyManager ausgeliefert.</p></body></html>"
    }

    /// Validate the current Caddyfile. Throws with Caddy's error text on failure.
    static func validate() throws {
        try ensureBinary()
        let r = Shell.run(binaryPath, ["validate", "--config", AppPaths.caddyfile.path, "--adapter", "caddyfile"])
        if !r.ok { throw CaddyError.command(r.stderr.isEmpty ? r.stdout : r.stderr) }
    }

    /// Write + validate + reload (no downtime). Talks to the admin API internally.
    static func apply(_ config: AppConfig) throws {
        try writeCaddyfile(config)
        try validate()
        try ensureBinary()
        let r = Shell.run(binaryPath, ["reload", "--config", AppPaths.caddyfile.path, "--adapter", "caddyfile"])
        if !r.ok { throw CaddyError.command(r.stderr.isEmpty ? r.stdout : r.stderr) }
    }

    /// Produce a bcrypt hash for a Basic-Auth password. Plaintext is passed via
    /// stdin so it never appears in the process argument list.
    static func hashPassword(_ plaintext: String) throws -> String {
        try ensureBinary()
        // caddy reads the password from stdin and needs a trailing newline,
        // otherwise it errors with EOF. Default algorithm is bcrypt ($2a$…),
        // which is exactly what the `basic_auth` directive expects.
        let r = Shell.run(binaryPath, ["hash-password"], stdin: plaintext + "\n")
        guard r.ok else { throw CaddyError.command(r.stderr.isEmpty ? r.stdout : r.stderr) }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the Caddy version string, or nil if the binary is missing/broken.
    static func version() -> String? {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else { return nil }
        let r = Shell.run(binaryPath, ["version"])
        return r.ok ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// Whether the admin API answers — i.e. a caddy process is actually running.
    static func isRunning() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else { return false }
        // `caddy reload` and friends require a running instance; the cheapest
        // liveness probe is hitting the admin endpoint directly.
        guard let url = URL(string: "http://127.0.0.1:2019/config/") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        let sem = DispatchSemaphore(value: 0)
        var alive = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) {
                alive = true
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 2.0)
        return alive
    }
}
