import SwiftUI

struct LogViewerView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var tailer = LogTailer()          // access logs
    @StateObject private var events = CaddyEventTailer()   // TLS/ACME events
    @State private var selectedHostID: UUID?

    private enum Mode: String, CaseIterable { case access = "Zugriffe", tls = "Zertifikat" }
    @State private var mode: Mode = .access

    private var selectedHost: ProxyHost? {
        model.config.hosts.first { $0.id == selectedHostID }
    }

    private var tlsEvents: [CaddyLogEvent] {
        guard let host = selectedHost else { return [] }
        return events.events.filter { $0.matches(domains: host.domains) }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .onChange(of: selectedHostID) { _ in startAccessTail() }
        .onChange(of: mode) { _ in startAccessTail() }
        .onAppear {
            events.start()
            startAccessTail()
        }
        .onDisappear {
            tailer.stop()
            events.stop()
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("Host", selection: $selectedHostID) {
                    Text("– wählen –").tag(UUID?.none)
                    ForEach(model.config.hosts) { host in
                        Text(host.primaryDomain).tag(UUID?.some(host.id))
                    }
                }
                .labelsHidden()
                Spacer()
                Text(countText).font(.caption).foregroundStyle(.secondary)
            }
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(8)
    }

    private var countText: String {
        guard selectedHost != nil else { return "" }
        return mode == .access ? "\(tailer.entries.count) Zugriffe" : "\(tlsEvents.count) Ereignisse"
    }

    @ViewBuilder
    private var content: some View {
        if selectedHostID == nil {
            ContentUnavailableCompat(title: "Kein Host gewählt",
                                     systemImage: "doc.text.magnifyingglass",
                                     description: "Wähle oben einen Host.")
        } else if mode == .access {
            accessContent
        } else {
            tlsContent
        }
    }

    @ViewBuilder
    private var accessContent: some View {
        if let host = selectedHost, !host.logging {
            ContentUnavailableCompat(title: "Logging deaktiviert",
                                     systemImage: "doc.text",
                                     description: "Access-Log ist für diesen Host ausgeschaltet.")
        } else if tailer.entries.isEmpty {
            ContentUnavailableCompat(title: "Noch keine Requests",
                                     systemImage: "clock",
                                     description: "Sobald Anfragen eintreffen, erscheinen sie hier live.")
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(tailer.entries) { entry in
                        AccessRow(entry: entry).id(entry.id)
                    }
                }
                .listStyle(.inset)
                .onChange(of: tailer.entries.count) { _ in
                    if let last = tailer.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private var tlsContent: some View {
        let items = tlsEvents
        if items.isEmpty {
            ContentUnavailableCompat(title: "Keine Zertifikatsereignisse",
                                     systemImage: "lock.shield",
                                     description: "Ausstellung/Erneuerung erscheint hier, sobald Caddy für diesen Host aktiv wird.")
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(items) { event in
                        TLSRow(event: event).id(event.id)
                    }
                }
                .listStyle(.inset)
                .onChange(of: items.count) { _ in
                    if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func startAccessTail() {
        guard mode == .access, let host = selectedHost, host.logging else {
            tailer.start(file: nil)
            return
        }
        tailer.start(file: AppPaths.logFile(for: host))
    }
}

private struct AccessRow: View {
    let entry: LogEntry
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(entry.status)")
                .font(.caption.monospaced().bold())
                .foregroundStyle(color)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.method) \(entry.uri)").font(.caption.monospaced()).lineLimit(1)
                Text("\(entry.remoteIP) • \(entry.timestamp.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
    private var color: Color {
        switch entry.statusColorName {
        case "green": return .green
        case "blue": return .blue
        case "orange": return .orange
        default: return .red
        }
    }
}

private struct TLSRow: View {
    let event: CaddyLogEvent
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(levelColor).frame(width: 8, height: 8).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.message).font(.caption).lineLimit(2)
                Text("\(shortLogger) • \(event.timestamp.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
    private var shortLogger: String {
        event.logger.hasPrefix("tls.") ? String(event.logger.dropFirst(4)) : event.logger
    }
    private var levelColor: Color {
        switch event.level {
        case "error", "fatal": return .red
        case "warn": return .orange
        default: return .green
        }
    }
}
