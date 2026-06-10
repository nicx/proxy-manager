import Foundation

/// Self-updates the bundled Caddy binary from the official GitHub releases.
/// Downloads the macOS arm64 build, ad-hoc signs it, strips quarantine, swaps it
/// in atomically and restarts the agent — with rollback if the new binary fails.
enum CaddyUpdater {
    struct ReleaseInfo {
        var version: String   // e.g. "2.8.4"
        var downloadURL: URL
    }

    enum UpdateError: LocalizedError {
        case network(String)
        case noAsset
        case extractionFailed(String)
        case verifyFailed
        var errorDescription: String? {
            switch self {
            case .network(let m): return "Netzwerkfehler: \(m)"
            case .noAsset: return "Kein passendes macOS-arm64-Asset im Release gefunden."
            case .extractionFailed(let m): return "Entpacken fehlgeschlagen: \(m)"
            case .verifyFailed: return "Neue Caddy-Binary startet nicht — Rollback durchgeführt."
            }
        }
    }

    static var installedVersion: String? { CaddyController.version() }

    /// Query the latest release tag and arm64 asset URL from GitHub.
    static func fetchLatest() async throws -> ReleaseInfo {
        let api = URL(string: "https://api.github.com/repos/caddyserver/caddy/releases/latest")!
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ProxyManager", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.network("HTTP \( (resp as? HTTPURLResponse)?.statusCode ?? -1 )")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tag = (json?["tag_name"] as? String) ?? ""
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = (json?["assets"] as? [[String: Any]]) ?? []
        // Asset name pattern: caddy_<version>_mac_arm64.tar.gz
        let match = assets.first { ($0["name"] as? String)?.contains("mac_arm64.tar.gz") == true }
        guard let urlString = match?["browser_download_url"] as? String,
              let url = URL(string: urlString) else {
            throw UpdateError.noAsset
        }
        return ReleaseInfo(version: version, downloadURL: url)
    }

    /// Download + install the given release, swapping the binary and restarting.
    static func install(_ release: ReleaseInfo) async throws {
        try AppPaths.ensureDirectories()
        let fm = FileManager.default

        // 1) Download the tarball to a temp location.
        let (tmpTar, resp) = try await URLSession.shared.download(from: release.downloadURL)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.network("Download HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let workDir = fm.temporaryDirectory.appendingPathComponent("pm-caddy-update-\(release.version)")
        try? fm.removeItem(at: workDir)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let tarPath = workDir.appendingPathComponent("caddy.tar.gz")
        try? fm.removeItem(at: tarPath)
        try fm.moveItem(at: tmpTar, to: tarPath)

        // 2) Extract.
        let untar = Shell.run("/usr/bin/tar", ["-xzf", tarPath.path, "-C", workDir.path])
        guard untar.ok else { throw UpdateError.extractionFailed(untar.stderr) }
        let extracted = workDir.appendingPathComponent("caddy")
        guard fm.isExecutableFile(atPath: extracted.path) else {
            throw UpdateError.extractionFailed("caddy nicht im Archiv")
        }

        // 3) Stage as caddy.new, make runnable on macOS (ad-hoc sign + de-quarantine).
        let newBin = AppPaths.binDir.appendingPathComponent("caddy.new")
        try? fm.removeItem(at: newBin)
        try fm.copyItem(at: extracted, to: newBin)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBin.path)
        _ = Shell.run("/usr/bin/xattr", ["-d", "com.apple.quarantine", newBin.path]) // ignore if absent
        let sign = Shell.run("/usr/bin/codesign", ["-s", "-", "-f", newBin.path])
        guard sign.ok else { throw UpdateError.extractionFailed("codesign: \(sign.stderr)") }

        // 4) Atomic swap with backup.
        if fm.fileExists(atPath: AppPaths.caddyBinary.path) {
            try? fm.removeItem(at: AppPaths.caddyBackup)
            try fm.moveItem(at: AppPaths.caddyBinary, to: AppPaths.caddyBackup)
        }
        try fm.moveItem(at: newBin, to: AppPaths.caddyBinary)

        // 5) Restart and verify; roll back on failure.
        do {
            try AgentInstaller.restart()
        } catch {
            try rollback()
            throw UpdateError.verifyFailed
        }
        try await Task.sleep(nanoseconds: 2_500_000_000)
        if !CaddyController.isRunning() {
            try rollback()
            throw UpdateError.verifyFailed
        }
    }

    private static func rollback() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: AppPaths.caddyBackup.path) else { return }
        try? fm.removeItem(at: AppPaths.caddyBinary)
        try fm.moveItem(at: AppPaths.caddyBackup, to: AppPaths.caddyBinary)
        try? AgentInstaller.restart()
    }
}
