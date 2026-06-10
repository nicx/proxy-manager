import SwiftUI

private let certDateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.locale = Locale(identifier: "de_DE")
    df.dateFormat = "dd.MM.yyyy"
    return df
}()

extension CertInfo {
    /// Higher = more urgent. Used to pick the "worst" status across a host's domains.
    var severity: Int {
        switch state {
        case .expired: return 4
        case .expiringSoon: return 3
        case .missing: return 2
        case .unknown: return 1
        case .valid: return 0
        }
    }

    var color: Color {
        switch state {
        case .valid: return .green
        case .expiringSoon: return .orange
        case .expired: return .red
        case .missing: return .secondary
        case .unknown: return .secondary
        }
    }

    var symbol: String {
        switch state {
        case .valid: return "lock.shield.fill"
        case .expiringSoon: return "exclamationmark.shield.fill"
        case .expired: return "xmark.shield.fill"
        case .missing: return "lock.open"
        case .unknown: return "questionmark.circle"
        }
    }

    var headline: String {
        switch state {
        case .valid: return "Gültig"
        case .expiringSoon: return "Läuft bald ab"
        case .expired: return "Abgelaufen"
        case .missing: return "Noch kein Zertifikat"
        case .unknown: return "Status unbekannt"
        }
    }

    var validUntilText: String? {
        guard let notAfter else { return nil }
        return certDateFormatter.string(from: notAfter)
    }

    /// Compact one-liner for the host list, e.g. "Gültig · 86 T.".
    var compactText: String {
        if state == .missing { return "kein Zertifikat" }
        if let days = daysRemaining, state != .unknown {
            return "\(headline) · \(days) T."
        }
        return headline
    }
}

/// Small inline SSL indicator for the host list. Reflects the *worst* status
/// across all of the host's domains, with a domain count when there's more than one.
struct CertBadge: View {
    let infos: [CertInfo]

    private var worst: CertInfo? {
        infos.max { $0.severity < $1.severity }
    }

    var body: some View {
        if let worst {
            HStack(spacing: 3) {
                Image(systemName: worst.symbol).font(.caption2)
                Text(text(worst)).font(.caption2)
            }
            .foregroundStyle(worst.color)
        } else {
            HStack(spacing: 3) {
                Image(systemName: "lock.slash").font(.caption2)
                Text("—").font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func text(_ worst: CertInfo) -> String {
        infos.count > 1 ? "\(worst.compactText) · \(infos.count) Domains" : worst.compactText
    }
}

/// Full SSL panel shown in the host editor: one row per domain (status, expiry,
/// issuer) with a per-domain manual renew button. Each domain has its own cert.
struct CertDetailView: View {
    @EnvironmentObject var model: AppModel
    let domains: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(domains.count > 1 ? "Status pro Domain (je ein Zertifikat)" : "Status")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.refreshCerts()
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Status aktualisieren")
            }

            ForEach(domains, id: \.self) { domain in
                domainRow(domain)
                if domain != domains.last { Divider() }
            }

            Text("Caddy erneuert automatisch ~30 Tage vor Ablauf. Eine manuelle Erneuerung startet den Dienst kurz neu und verbraucht ein Let's-Encrypt-Kontingent (Rate-Limits beachten).")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func domainRow(_ domain: String) -> some View {
        let info = model.certInfos[domain]
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: info?.symbol ?? "lock.slash")
                        .font(.caption)
                        .foregroundStyle(info?.color ?? .secondary)
                    Text(domain).font(.caption).fontWeight(.medium).lineLimit(1)
                }
                Text(detailText(info)).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button("Erneuern") { model.renewCert(domain: domain) }
                .controlSize(.small)
                .disabled(model.busy)
        }
    }

    private func detailText(_ info: CertInfo?) -> String {
        guard let info else { return "Status unbekannt" }
        var parts = [info.headline]
        if let until = info.validUntilText {
            parts.append("bis \(until)" + (info.daysRemaining.map { " (\($0) T.)" } ?? ""))
        }
        if let issuer = info.issuer { parts.append(issuer) }
        return parts.joined(separator: " · ")
    }
}
