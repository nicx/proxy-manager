import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var settings: AppSettings = AppSettings()
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                group("Let's Encrypt") {
                    TextField("ACME-Kontakt-E-Mail", text: $settings.acmeEmail)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Staging-CA verwenden (zum Testen, ohne Rate-Limits)", isOn: $settings.useStagingCA)
                    Text("Staging stellt ungültige Test-Zertifikate aus. Für den Echtbetrieb aus lassen.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                group("Ports") {
                    HStack {
                        Text("HTTP-Port"); Spacer()
                        TextField("", value: $settings.httpPort, format: .number.grouping(.never)).frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("HTTPS-Port"); Spacer()
                        TextField("", value: $settings.httpsPort, format: .number.grouping(.never)).frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Router so einstellen: extern 80 → \(settings.httpPort), extern 443 → \(settings.httpsPort).")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                group("Logging") {
                    Picker("Caddy-Log-Level", selection: $settings.logLevel) {
                        ForEach(["DEBUG", "INFO", "WARN", "ERROR"], id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                group("Autostart") {
                    Toggle("ProxyManager beim Login automatisch starten", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    .disabled(!model.loginItemAvailable)
                    Text(model.loginItemAvailable
                         ? "Der Proxy-Dienst (Caddy) startet ohnehin schon beim Login; dies betrifft nur das Menüleisten-Fenster."
                         : "Nur in der installierten .app verfügbar (nicht bei `swift run`).")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Button("Einstellungen speichern & anwenden") {
                    model.saveSettings(settings)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .onAppear {
            if !loaded { settings = model.config.settings; loaded = true }
        }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).fontWeight(.semibold)
            content()
        }
    }
}
