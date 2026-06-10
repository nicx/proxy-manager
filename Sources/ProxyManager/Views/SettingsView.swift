import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var settings: AppSettings = AppSettings()
    @State private var loaded = false
    @State private var showFolderPicker = false

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

                group("Benachrichtigungen") {
                    Toggle("E-Mail bei Fehlern senden", isOn: $settings.notifyOnError)
                    TextField("Empfänger-Adresse", text: $settings.notifyEmail)
                        .textFieldStyle(.roundedBorder)
                    DisclosureGroup("SMTP-Relay (erweitert)") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Absender (leer = automatisch)", text: $settings.notifyFrom)
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                TextField("Host", text: $settings.smtpHost)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Port", value: $settings.smtpPort, format: .number.grouping(.never))
                                    .textFieldStyle(.roundedBorder).frame(width: 80)
                            }
                            Text("Standard 127.0.0.1:2525 — lokaler Relay (z. B. MailRelay).")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                    Button("Testmail senden") { model.sendTestMail(settings) }
                        .disabled(model.busy || settings.notifyEmail.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                group("Automatisches Backup") {
                    Toggle("Bei jeder Änderung sichern", isOn: $settings.backupEnabled)
                    HStack {
                        TextField("Backup-Ordner", text: $settings.backupFolder)
                            .textFieldStyle(.roundedBorder)
                        Button("Wählen…") { showFolderPicker = true }
                    }
                    HStack {
                        Button("Jetzt sichern") { model.backupNow(settings) }
                            .disabled(model.busy || settings.backupFolder.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                    }
                    Text("Schreibt zeitgestempelte JSON-Kopien (ohne Zertifikate) und behält die letzten 30. Tipp: einen iCloud-synchronisierten Ordner wählen.")
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
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                settings.backupFolder = url.path
            }
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
