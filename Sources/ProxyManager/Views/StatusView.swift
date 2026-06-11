import SwiftUI
import AppKit

struct StatusView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                group("Dienst") {
                    row("Caddy-Version", model.caddyVersion)
                    row("Läuft", model.caddyRunning ? "ja" : "nein")
                    row("Agent installiert", model.agentInstalled ? "ja" : "nein")
                }

                group("Steuerung") {
                    if model.agentInstalled {
                        HStack {
                            Button("Neu starten") { model.restartService() }
                            Button("Stoppen") { model.stopService() }
                            Button("Starten") { model.startService() }
                        }
                        Button("Dienst entfernen", role: .destructive) { model.uninstallService() }
                    } else {
                        Button("Dienst installieren & starten") { model.installService() }
                            .keyboardShortcut(.defaultAction)
                    }
                }

                group("Caddy-Update") {
                    if let v = model.updateAvailable {
                        Label("Update verfügbar: \(v)", systemImage: "arrow.down.circle")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Caddy ist aktuell.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Auf neueste Caddy-Version aktualisieren") { model.updateCaddy() }
                        .disabled(model.busy)
                    Text("Lädt die offizielle macOS-arm64-Binary, signiert sie ad-hoc und tauscht sie mit Rollback.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                group("Dateien") {
                    Button("Konfigurationsordner öffnen") {
                        NSWorkspace.shared.open(AppPaths.appSupport)
                    }
                    Text(AppPaths.appSupport.path)
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                group("Hinweis 24/7") {
                    Text("Der Dienst läuft als User-LaunchAgent — also solange dieser Benutzer angemeldet ist. Für unterbrechungsfreien Betrieb nach Neustart die automatische Anmeldung in den Systemeinstellungen aktivieren.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).textSelection(.enabled)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).fontWeight(.semibold)
            content()
        }
    }
}
