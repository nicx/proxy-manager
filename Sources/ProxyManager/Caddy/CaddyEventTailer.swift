import Foundation
import Combine

/// A structured Caddy runtime log line (used for TLS/ACME events).
struct CaddyLogEvent: Identifiable {
    let id = UUID()
    var timestamp: Date
    var level: String
    var logger: String
    var message: String
    /// Domains referenced by the entry (identifier/identifiers/sans/names/domain).
    var domains: [String]
    var raw: String

    var isProblem: Bool { level == "error" || level == "warn" || level == "fatal" }

    /// Does this event concern the given host's domains?
    func matches(domains hostDomains: [String]) -> Bool {
        if domains.contains(where: hostDomains.contains) { return true }
        // Fallback: some ACME logs bury the name in nested fields → scan raw line.
        return hostDomains.contains { raw.contains($0) }
    }
}

/// Tails Caddy's default JSON log and keeps only TLS/ACME-related events
/// (logger names beginning with "tls"). The view filters these per host.
@MainActor
final class CaddyEventTailer: ObservableObject {
    @Published private(set) var events: [CaddyLogEvent] = []

    private var tail = FileTail()
    private var timer: Timer?
    private let maxEntries = 1000

    func start() {
        stop()
        events = []
        tail.reset()
        poll()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
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
        for line in tail.newLines(from: AppPaths.globalLog) {
            if let event = parse(line) { events.append(event) }
        }
        if events.count > maxEntries {
            events.removeFirst(events.count - maxEntries)
        }
    }

    private func parse(_ data: Data) -> CaddyLogEvent? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let logger = (obj["logger"] as? String) ?? ""
        // Only keep certificate/TLS lifecycle events.
        guard logger.hasPrefix("tls") else { return nil }

        let ts = (obj["ts"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        var domains = Set<String>()
        if let s = obj["identifier"] as? String { domains.insert(s) }
        if let s = obj["domain"] as? String { domains.insert(s) }
        for key in ["identifiers", "sans", "names"] {
            if let arr = obj[key] as? [String] { domains.formUnion(arr) }
        }

        return CaddyLogEvent(
            timestamp: ts,
            level: (obj["level"] as? String) ?? "",
            logger: logger,
            message: (obj["msg"] as? String) ?? "",
            domains: Array(domains),
            raw: String(decoding: data, as: UTF8.self)
        )
    }
}
