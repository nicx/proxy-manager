import SwiftUI

struct HostListView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: ProxyHost?

    var body: some View {
        Group {
            if let host = editing {
                // Inline editor (NOT a sheet): a sheet inside a MenuBarExtra window
                // dismisses the whole menu. Swapping the content keeps focus.
                HostEditorView(
                    host: host,
                    onSave: { model.upsert($0) },
                    onClose: { editing = nil }
                )
                .environmentObject(model)
            } else {
                listContent
            }
        }
    }

    private var listContent: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.config.hosts.isEmpty {
                ContentUnavailableCompat(
                    title: "Keine Hosts",
                    systemImage: "globe",
                    description: "Lege deinen ersten Proxy-Host an."
                )
            } else {
                List {
                    ForEach(model.config.hosts) { host in
                        HostRow(host: host, onEdit: { editing = host })
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Button {
                editing = ProxyHost()
            } label: { Label("Host", systemImage: "plus") }
            Spacer()
            Button {
                if let url = FilePanels.openJSON() { model.importConfig(from: url) }
            } label: { Image(systemName: "square.and.arrow.down") }
                .help("Konfiguration importieren")
            Button {
                if let url = FilePanels.saveJSON(suggestedName: "proxymanager-config.json") {
                    model.export(to: url)
                }
            } label: { Image(systemName: "square.and.arrow.up") }
                .help("Konfiguration exportieren")
        }
        .padding(8)
    }
}

private struct HostRow: View {
    @EnvironmentObject var model: AppModel
    let host: ProxyHost
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { host.enabled },
                set: { _ in model.toggle(host) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            // Tappable edit area — a real Button is reliable inside a MenuBarExtra
            // window, unlike onTapGesture which can swallow clicks.
            Button(action: onEdit) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.domains.joined(separator: ", "))
                            .font(.body).fontWeight(.medium)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Image(systemName: host.target == .staticPage ? "doc.richtext" : "arrow.right")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(host.targetDisplay)
                                .font(.caption).foregroundStyle(.secondary)
                            if host.basicAuth != nil {
                                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                            }
                            if !host.allowCIDRs.isEmpty || !host.denyCIDRs.isEmpty {
                                Image(systemName: "shield.lefthalf.filled").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        CertBadge(infos: host.domains.map {
                            model.certInfos[$0] ?? CertInfo(domain: $0, notAfter: nil, issuer: nil, state: .unknown)
                        })
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .opacity(host.enabled ? 1 : 0.5)
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                model.delete(host)
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

/// Fallback for ContentUnavailableView (macOS 14+) so we build on macOS 13.
struct ContentUnavailableCompat: View {
    let title: String
    let systemImage: String
    let description: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(description).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

