import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            Divider()
            TabView {
                HostListView()
                    .tabItem { Label("Hosts", systemImage: "globe") }
                LogViewerView()
                    .tabItem { Label("Logs", systemImage: "doc.text.magnifyingglass") }
                SettingsView()
                    .tabItem { Label("Einstellungen", systemImage: "gearshape") }
                StatusView()
                    .tabItem { Label("Status", systemImage: "heart.text.square") }
            }
            .padding(.top, 4)
            StatusBar()
        }
    }
}

/// Top header with the live service indicator and a quit button.
private struct HeaderView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Circle()
                .fill(model.caddyRunning ? Color.green : Color.secondary)
                .frame(width: 10, height: 10)
            Text(model.caddyRunning ? "Caddy läuft" : (model.agentInstalled ? "Caddy gestoppt" : "Dienst nicht installiert"))
                .font(.headline)
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Button {
                NSApp.terminate(nil)
            } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .help("ProxyManager beenden")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Bottom bar showing the last status / error message.
private struct StatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let err = model.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if let msg = model.statusMessage {
                Label(msg, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                EmptyView()
            }
        }
        .font(.caption)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
