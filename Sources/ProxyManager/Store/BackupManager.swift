import Foundation

/// Writes timestamped JSON backups of the configuration to a user-chosen folder
/// and keeps only the most recent `keep` of them. Certificates are NOT included.
enum BackupManager {
    static let keep = 30
    static let prefix = "proxymanager-"

    private static let stamp: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df
    }()

    /// Write a snapshot into `folder`, creating the folder if needed, then prune.
    static func write(_ config: AppConfig, toFolder folder: String) throws {
        let dir = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("\(prefix)\(stamp.string(from: Date())).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)

        prune(in: dir)
    }

    /// Keep only the newest `keep` snapshots (filenames sort chronologically).
    private static func prune(in dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        let backups = files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard backups.count > keep else { return }
        for url in backups.prefix(backups.count - keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
