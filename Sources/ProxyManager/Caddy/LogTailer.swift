import Foundation
import Combine

struct LogEntry: Identifiable {
    let id = UUID()
    var timestamp: Date
    var status: Int
    var method: String
    var host: String
    var uri: String
    var remoteIP: String
    var raw: String

    var statusColorName: String {
        switch status {
        case 200..<300: return "green"
        case 300..<400: return "blue"
        case 400..<500: return "orange"
        default: return "red"
        }
    }
}

/// Tails a single Caddy JSON access-log file by polling for appended bytes.
@MainActor
final class LogTailer: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    @Published var fileURL: URL?

    private var tail = FileTail()
    private var timer: Timer?
    private let maxEntries = 500

    func start(file: URL?) {
        stop()
        entries = []
        tail.reset()
        fileURL = file
        guard file != nil else { return }
        // Prime with the existing tail of the file, then poll.
        poll()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let url = fileURL else { return }
        for line in tail.newLines(from: url) {
            if let entry = parse(line) { entries.append(entry) }
        }
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    private func parse(_ data: Data) -> LogEntry? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let request = obj["request"] as? [String: Any] ?? [:]
        let ts = (obj["ts"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        return LogEntry(
            timestamp: ts,
            status: (obj["status"] as? Int) ?? 0,
            method: (request["method"] as? String) ?? "",
            host: (request["host"] as? String) ?? "",
            uri: (request["uri"] as? String) ?? "",
            remoteIP: (request["remote_ip"] as? String) ?? "",
            raw: String(decoding: data, as: UTF8.self)
        )
    }
}
