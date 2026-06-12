import Foundation

/// Installs a pf (packet filter) redirect so the Mac answers on the privileged
/// ports 80/443 while Caddy keeps running root-free on its high ports
/// (httpPort/httpsPort). This lets internal clients reach the Mac directly on
/// 443 via local/split-horizon DNS — sidestepping broken NAT hairpin.
///
/// Caddy itself is untouched; only a small system-level pf boot daemon is added,
/// installed once with a single admin prompt.
enum PortForwarder {
    static let label = "com.proxymanager.pf"
    static let anchorPath = "/etc/pf.anchors/com.proxymanager"
    static let confPath = "/etc/pf-proxymanager.conf"
    static let daemonPath = "/Library/LaunchDaemons/com.proxymanager.pf.plist"

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

    /// Whether the pf boot daemon is installed.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: daemonPath)
    }

    /// Set up the 80→httpPort and 443→httpsPort redirect and persist it.
    static func install(httpPort: Int, httpsPort: Int) throws {
        try runPrivileged(installScript(httpPort: httpPort, httpsPort: httpsPort))
    }

    /// Remove the redirect and restore the default pf ruleset.
    static func uninstall() throws {
        try runPrivileged(uninstallScript())
    }

    // MARK: - Scripts

    private static func installScript(httpPort: Int, httpsPort: Int) -> String {
        """
        #!/bin/sh
        set -e
        mkdir -p /etc/pf.anchors

        cat > '\(anchorPath)' <<'ANCHOR'
        rdr pass inet proto tcp from any to any port 80 -> 127.0.0.1 port \(httpPort)
        rdr pass inet proto tcp from any to any port 443 -> 127.0.0.1 port \(httpsPort)
        ANCHOR

        cat > '\(confPath)' <<'CONF'
        scrub-anchor "com.apple/*"
        nat-anchor "com.apple/*"
        rdr-anchor "com.apple/*"
        rdr-anchor "com.proxymanager"
        dummynet-anchor "com.apple/*"
        anchor "com.apple/*"
        load anchor "com.apple" from "/etc/pf.anchors/com.apple"
        load anchor "com.proxymanager" from "\(anchorPath)"
        CONF

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
                <string>\(confPath)</string>
            </array>
            <key>RunAtLoad</key><true/>
        </dict>
        </plist>
        PLIST

        chown root:wheel '\(anchorPath)' '\(confPath)' '\(daemonPath)'
        chmod 644 '\(anchorPath)' '\(confPath)' '\(daemonPath)'

        # Validate syntax before activating.
        /sbin/pfctl -nf '\(confPath)'

        launchctl bootout system '\(daemonPath)' 2>/dev/null || true
        launchctl bootstrap system '\(daemonPath)'
        /sbin/pfctl -E -f '\(confPath)'
        """
    }

    private static func uninstallScript() -> String {
        """
        #!/bin/sh
        launchctl bootout system '\(daemonPath)' 2>/dev/null || true
        rm -f '\(daemonPath)' '\(confPath)' '\(anchorPath)'
        /sbin/pfctl -f /etc/pf.conf 2>/dev/null || true
        """
    }

    // MARK: - Privileged execution

    /// Write the script to a temp file and run it once with administrator
    /// privileges via osascript (single password prompt).
    private static func runPrivileged(_ script: String) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-pf-\(UUID().uuidString).sh")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let apple = "do shell script \"/bin/sh \\\"\(tmp.path)\\\"\" with administrator privileges"
        let r = Shell.run("/usr/bin/osascript", ["-e", apple])
        if !r.ok {
            let msg = (r.stderr + r.stdout).lowercased()
            if msg.contains("cancel") || msg.contains("(-128)") {
                throw PFError.cancelled
            }
            throw PFError.command((r.stderr.isEmpty ? r.stdout : r.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
