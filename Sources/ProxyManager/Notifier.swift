import Foundation

/// Sends notification e-mails through a local SMTP relay (e.g. MailRelay on
/// 127.0.0.1:2525) using the system `curl`. The relay handles upstream
/// auth/TLS; local submission is plain SMTP, no auth.
enum Notifier {
    private static let rfc822: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return df
    }()

    static func defaultFrom(_ settings: AppSettings) -> String {
        let f = settings.notifyFrom.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? "proxymanager@\(ProcessInfo.processInfo.hostName)" : f
    }

    /// Send a message. Throws on missing recipient or transport failure.
    /// Does NOT check `notifyOnError` — that gate lives in the caller so the
    /// settings "Testmail" button can send even before notifications are enabled.
    static func send(subject: String, body: String, settings: AppSettings) throws {
        let to = settings.notifyEmail.trimmingCharacters(in: .whitespaces)
        guard !to.isEmpty else { throw SimpleError("Keine Empfängeradresse konfiguriert.") }
        let from = defaultFrom(settings)
        let message = buildMessage(from: from, to: to, subject: subject, body: body)

        let r = Shell.run("/usr/bin/curl", [
            "--silent", "--show-error",
            "--connect-timeout", "10", "--max-time", "30",
            "--url", "smtp://\(settings.smtpHost):\(settings.smtpPort)",
            "--mail-from", from,
            "--mail-rcpt", to,
            "-T", "-",
        ], stdin: message)

        if !r.ok {
            throw SimpleError("Mail-Versand fehlgeschlagen: \(r.stderr.isEmpty ? r.stdout : r.stderr)")
        }
    }

    /// RFC 822 message with CRLF line endings. Subject is MIME-encoded so umlauts
    /// survive; the body is sent as UTF-8.
    private static func buildMessage(from: String, to: String, subject: String, body: String) -> String {
        let headers = [
            "From: ProxyManager <\(from)>",
            "To: <\(to)>",
            "Subject: \(encodeHeader(subject))",
            "Date: \(rfc822.string(from: Date()))",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 8bit",
        ]
        let normalizedBody = body.replacingOccurrences(of: "\r\n", with: "\n")
                                 .replacingOccurrences(of: "\n", with: "\r\n")
        return headers.joined(separator: "\r\n") + "\r\n\r\n" + normalizedBody + "\r\n"
    }

    /// MIME encoded-word (RFC 2047) for non-ASCII subjects.
    private static func encodeHeader(_ s: String) -> String {
        if s.allSatisfy({ $0.isASCII }) { return s }
        let b64 = Data(s.utf8).base64EncodedString()
        return "=?UTF-8?B?\(b64)?="
    }
}
