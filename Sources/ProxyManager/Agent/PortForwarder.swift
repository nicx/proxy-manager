import Foundation

/// Installs a pf (packet filter) redirect so the Mac answers on the privileged
/// ports 80/443 while Caddy keeps running root-free on its high ports.
///
/// Coexistence model: we register a *named anchor* in the system's main ruleset
/// `/etc/pf.conf` (idempotently) and load that shared file — rather than
/// replacing the whole ruleset. This lets other pf-using apps (e.g. MailRelay,
/// which registers its own `mailrelay` anchor the same way) stay active at the
/// same time. The pf.conf rewrite is computed in Swift (it's world-readable);
/// the privileged step only copies files and loads pf.
enum PortForwarder {
    static let label = "com.proxymanager.pf"
    static let anchorName = "com.proxymanager"
    static let anchorPath = "/etc/pf.anchors/com.proxymanager"
    static let pfConfPath = "/etc/pf.conf"
    static let daemonPath = "/Library/LaunchDaemons/com.proxymanager.pf.plist"

    /// Fallback if /etc/pf.conf is somehow missing (mirrors Apple's default).
    private static let defaultPfConf = """
    scrub-anchor "com.apple/*"
    nat-anchor "com.apple/*"
    rdr-anchor "com.apple/*"
    dummynet-anchor "com.apple/*"
    anchor "com.apple/*"
    load anchor "com.apple" from "/etc/pf.anchors/com.apple"
    """

    enum PFError: LocalizedError {
        case cancelled
        case command(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Vorgang abgebrochen (Admin-Berechtigung verweigert)."
            case .command(let m): return "pf-Einrichtung fehlgeschlagen: \(m)"
            }
        }
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: daemonPath)
    }

    private static var rdrAnchorLine: String { "rdr-anchor \"\(anchorName)\"" }
    private static var loadAnchorLine: String { "load anchor \"\(anchorName)\" from \"\(anchorPath)\"" }

    // MARK: - Public actions

    static func install(httpPort: Int, httpsPort: Int) throws {
        let updated = confByAddingAnchor(currentPfConf())
        try runPrivileged(installScript(httpPort: httpPort, httpsPort: httpsPort), confContent: updated)
    }

    static func uninstall() throws {
        let updated = confByRemovingAnchor(currentPfConf())
        try runPrivileged(uninstallScript(), confContent: updated)
    }

    // MARK: - pf.conf editing (idempotent, preserves other anchors)

    private static func currentPfConf() -> String {
        (try? String(contentsOf: URL(fileURLWithPath: pfConfPath), encoding: .utf8)) ?? defaultPfConf
    }

    static func confByAddingAnchor(_ original: String) -> String {
        var lines = original.components(separatedBy: "\n")
        // Normalize trailing blank lines so repeated runs are fully idempotent.
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }

        if !lines.contains(rdrAnchorLine) {
            // rdr-anchor must sit in the translation section (with other
            // rdr-anchors), before the filter `anchor` lines.
            let idx = lastIndex(withPrefix: "rdr-anchor", in: lines)
                ?? lastIndex(withPrefix: "nat-anchor", in: lines)
                ?? lastIndex(withPrefix: "scrub-anchor", in: lines)
            if let idx { lines.insert(rdrAnchorLine, at: idx + 1) }
            else { lines.insert(rdrAnchorLine, at: 0) }
        }
        if !lines.contains(loadAnchorLine) {
            lines.append(loadAnchorLine)  // load statements can go at the end
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func confByRemovingAnchor(_ original: String) -> String {
        original.components(separatedBy: "\n")
            .filter { $0 != rdrAnchorLine && $0 != loadAnchorLine }
            .joined(separator: "\n")
    }

    private static func lastIndex(withPrefix prefix: String, in lines: [String]) -> Int? {
        lines.lastIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }
    }

    // MARK: - Scripts (run as root; reference the prepared pf.conf via __CONF__)

    private static func installScript(httpPort: Int, httpsPort: Int) -> String {
        """
        #!/bin/sh
        set -e
        mkdir -p /etc/pf.anchors

        cat > '\(anchorPath)' <<'ANCHOR'
        rdr pass inet proto tcp from any to any port 80 -> 127.0.0.1 port \(httpPort)
        rdr pass inet proto tcp from any to any port 443 -> 127.0.0.1 port \(httpsPort)
        ANCHOR
        chown root:wheel '\(anchorPath)'; chmod 644 '\(anchorPath)'

        # One-time backup of the original system ruleset.
        cp -n /etc/pf.conf /etc/pf.conf.orig.proxymanager 2>/dev/null || true

        # Validate the new ruleset (anchor file is already in place), then install it.
        /sbin/pfctl -nf '__CONF__'
        cp '__CONF__' /etc/pf.conf
        chown root:wheel /etc/pf.conf; chmod 644 /etc/pf.conf

        cat > '\(daemonPath)' <<'PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/sbin/pfctl</string>
                <string>-E</string>
                <string>-f</string>
                <string>/etc/pf.conf</string>
            </array>
            <key>RunAtLoad</key><true/>
        </dict>
        </plist>
        PLIST
        chown root:wheel '\(daemonPath)'; chmod 644 '\(daemonPath)'

        launchctl bootout system '\(daemonPath)' 2>/dev/null || true
        launchctl bootstrap system '\(daemonPath)'
        /sbin/pfctl -E -f /etc/pf.conf
        """
    }

    private static func uninstallScript() -> String {
        """
        #!/bin/sh
        launchctl bootout system '\(daemonPath)' 2>/dev/null || true
        rm -f '\(daemonPath)' '\(anchorPath)'
        cp '__CONF__' /etc/pf.conf
        chown root:wheel /etc/pf.conf; chmod 644 /etc/pf.conf
        /sbin/pfctl -E -f /etc/pf.conf
        """
    }

    // MARK: - Privileged execution

    private static func runPrivileged(_ scriptTemplate: String, confContent: String) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pm-pf-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let confTmp = dir.appendingPathComponent("pf.conf")
        try confContent.write(to: confTmp, atomically: true, encoding: .utf8)

        let script = scriptTemplate.replacingOccurrences(of: "__CONF__", with: confTmp.path)
        let scriptTmp = dir.appendingPathComponent("run.sh")
        try script.write(to: scriptTmp, atomically: true, encoding: .utf8)

        let apple = "do shell script \"/bin/sh \\\"\(scriptTmp.path)\\\"\" with administrator privileges"
        let r = Shell.run("/usr/bin/osascript", ["-e", apple])
        if !r.ok {
            let msg = (r.stderr + r.stdout).lowercased()
            if msg.contains("cancel") || msg.contains("(-128)") { throw PFError.cancelled }
            throw PFError.command((r.stderr.isEmpty ? r.stdout : r.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
