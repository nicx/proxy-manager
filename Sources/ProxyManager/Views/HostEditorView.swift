import SwiftUI

struct HostEditorView: View {
    @EnvironmentObject var model: AppModel

    @State private var host: ProxyHost
    @State private var domainsText: String
    @State private var allowText: String
    @State private var denyText: String
    @State private var target: HostTarget
    @State private var staticContent: String

    @State private var authEnabled: Bool
    @State private var authUser: String
    @State private var authPassword: String = ""
    private let existingHash: String?

    @State private var saving = false
    @State private var error: String?

    let onSave: (ProxyHost) -> Void
    let onClose: () -> Void

    init(host: ProxyHost,
         onSave: @escaping (ProxyHost) -> Void,
         onClose: @escaping () -> Void) {
        _host = State(initialValue: host)
        _domainsText = State(initialValue: host.domains.joined(separator: "\n"))
        _allowText = State(initialValue: host.allowCIDRs.joined(separator: "\n"))
        _denyText = State(initialValue: host.denyCIDRs.joined(separator: "\n"))
        _target = State(initialValue: host.target)
        _staticContent = State(initialValue: host.staticContent)
        _authEnabled = State(initialValue: host.basicAuth != nil)
        _authUser = State(initialValue: host.basicAuth?.username ?? "")
        existingHash = host.basicAuth?.bcryptHash
        self.onSave = onSave
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Zurück zur Liste")
                Text(host.domains.isEmpty ? "Neuer Host" : "Host bearbeiten").font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    domainSection
                    targetSection
                    if target == .proxy {
                        upstreamSection
                    } else {
                        staticSection
                    }
                    sslSection
                    authSection
                    accessSection
                    loggingSection
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
                .padding(12)
            }

            Divider()
            HStack {
                Button("Abbrechen") { onClose() }
                Spacer()
                Button(saving ? "Speichere…" : "Speichern") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sections

    private var domainSection: some View {
        section("Domains", hint: "Eine pro Zeile. Für jede gibt es ein eigenes Let's-Encrypt-Zertifikat.") {
            TextEditor(text: $domainsText)
                .font(.body.monospaced())
                .frame(height: 60)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }

    private var targetSection: some View {
        section("Ziel-Typ", hint: nil) {
            Picker("", selection: $target) {
                Text("Reverse-Proxy").tag(HostTarget.proxy)
                Text("Statische Seite").tag(HostTarget.staticPage)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var staticSection: some View {
        section("Seiteninhalt (HTML)",
                hint: "Wird unter „/“ ausgeliefert. Reiner Text erscheint ebenfalls als HTML-Seite.") {
            TextEditor(text: $staticContent)
                .font(.body.monospaced())
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }

    private var upstreamSection: some View {
        section("Ziel (Backend)", hint: nil) {
            HStack {
                Picker("", selection: $host.upstreamScheme) {
                    Text("http").tag(UpstreamScheme.http)
                    Text("https").tag(UpstreamScheme.https)
                }
                .labelsHidden().frame(width: 90)
                TextField("Host/IP", text: $host.upstreamHost)
                Text(":")
                TextField("Port", value: $host.upstreamPort, format: .number.grouping(.never))
                    .frame(width: 70)
            }
            if host.upstreamScheme == .https {
                Toggle("TLS-Zertifikat des Backends nicht prüfen (für UniFi & selbstsignierte Geräte)",
                       isOn: $host.skipTLSVerify)
                    .font(.callout)
            }
            Toggle("Origin auf Backend umschreiben (nötig für WebSockets bei UniFi OS)",
                   isOn: $host.rewriteOriginToUpstream)
                .font(.callout)
        }
    }

    @ViewBuilder
    private var sslSection: some View {
        let isExisting = model.config.hosts.contains { $0.id == host.id }
        if isExisting && !host.primaryDomain.isEmpty {
            section("SSL-Zertifikat", hint: nil) {
                CertDetailView(domains: host.domains)
                    .environmentObject(model)
            }
        }
    }

    private var authSection: some View {
        section("Basic-Auth", hint: "Passwort wird als bcrypt-Hash gespeichert, nie im Klartext.") {
            Toggle("Basic-Auth aktivieren", isOn: $authEnabled)
            if authEnabled {
                TextField("Benutzername", text: $authUser)
                SecureField(existingHash != nil ? "Neues Passwort (leer = unverändert)" : "Passwort",
                            text: $authPassword)
                Toggle("Nur von extern verlangen (interne Netze ausnehmen)",
                       isOn: $host.basicAuthSkipInternal)
                if host.basicAuthSkipInternal {
                    Text("Interne Quellen ohne Abfrage: \(model.config.settings.internalCIDRs.joined(separator: ", ")). Anpassbar in den Einstellungen. Wichtig: nur zuverlässig, wenn externe Anfragen ihre echte Quell-IP behalten (von extern testen!).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var accessSection: some View {
        section("Access-Listen (IP/CIDR)", hint: "Je eine pro Zeile. Allow gesetzt ⇒ nur diese dürfen, Rest 403.") {
            Text("Erlauben (Allow)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $allowText)
                .font(.body.monospaced()).frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text("Sperren (Deny)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $denyText)
                .font(.body.monospaced()).frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }

    private var loggingSection: some View {
        section("Logging", hint: nil) {
            Toggle("Access-Log für diesen Host schreiben", isOn: $host.logging)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, hint: String?,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).fontWeight(.semibold)
            content()
            if let hint { Text(hint).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    // MARK: - Save

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func save() {
        var updated = host
        updated.domains = lines(domainsText)
        updated.allowCIDRs = lines(allowText)
        updated.denyCIDRs = lines(denyText)
        updated.target = target
        updated.staticContent = staticContent

        if let err = updated.validationError() { error = err; return }

        saving = true
        error = nil
        Task {
            do {
                if authEnabled {
                    let user = authUser.trimmingCharacters(in: .whitespaces)
                    guard !user.isEmpty else { throw SimpleError("Benutzername fehlt.") }
                    let hash: String
                    if authPassword.isEmpty, let existingHash {
                        hash = existingHash
                    } else if !authPassword.isEmpty {
                        let pw = authPassword
                        hash = try await Task.detached { try CaddyController.hashPassword(pw) }.value
                    } else {
                        throw SimpleError("Passwort fehlt.")
                    }
                    updated.basicAuth = BasicAuth(username: user, bcryptHash: hash)
                } else {
                    updated.basicAuth = nil
                }
                onSave(updated)
                onClose()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

struct SimpleError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
