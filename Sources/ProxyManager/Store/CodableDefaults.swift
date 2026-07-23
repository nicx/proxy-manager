import Foundation

/// Decode a key, falling back to a default when the key is missing OR the value
/// has the wrong type. Without this, adding a new field to a Codable struct makes
/// older JSON (e.g. an existing config.json or an exported backup) fail to decode
/// entirely — which would silently wipe the configuration on upgrade.
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

// Tolerant decoders: start from defaults (via the memberwise initializer, kept
// because these custom inits live in extensions) and overlay present keys.

extension ProxyHost {
    enum CodingKeys: String, CodingKey {
        case id, enabled, domains, target, staticContent, upstreamScheme,
             upstreamHost, upstreamPort, skipTLSVerify, rewriteOriginToUpstream,
             basicAuth, basicAuthSkipInternal, allowCIDRs, denyCIDRs, logging
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, id)
        enabled = c.value(.enabled, enabled)
        domains = c.value(.domains, domains)
        target = c.value(.target, target)
        staticContent = c.value(.staticContent, staticContent)
        upstreamScheme = c.value(.upstreamScheme, upstreamScheme)
        upstreamHost = c.value(.upstreamHost, upstreamHost)
        upstreamPort = c.value(.upstreamPort, upstreamPort)
        skipTLSVerify = c.value(.skipTLSVerify, skipTLSVerify)
        rewriteOriginToUpstream = c.value(.rewriteOriginToUpstream, rewriteOriginToUpstream)
        basicAuth = (try? c.decodeIfPresent(BasicAuth.self, forKey: .basicAuth)) ?? nil
        basicAuthSkipInternal = c.value(.basicAuthSkipInternal, basicAuthSkipInternal)
        allowCIDRs = c.value(.allowCIDRs, allowCIDRs)
        denyCIDRs = c.value(.denyCIDRs, denyCIDRs)
        logging = c.value(.logging, logging)
    }
}

extension AppSettings {
    enum CodingKeys: String, CodingKey {
        case acmeEmail, useStagingCA, httpPort, httpsPort, logLevel,
             notifyOnError, notifyEmail, notifyFrom, smtpHost, smtpPort,
             backupEnabled, backupFolder, notifyOnUpdate, internalCIDRs
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        acmeEmail = c.value(.acmeEmail, acmeEmail)
        useStagingCA = c.value(.useStagingCA, useStagingCA)
        httpPort = c.value(.httpPort, httpPort)
        httpsPort = c.value(.httpsPort, httpsPort)
        logLevel = c.value(.logLevel, logLevel)
        notifyOnError = c.value(.notifyOnError, notifyOnError)
        notifyEmail = c.value(.notifyEmail, notifyEmail)
        notifyFrom = c.value(.notifyFrom, notifyFrom)
        smtpHost = c.value(.smtpHost, smtpHost)
        smtpPort = c.value(.smtpPort, smtpPort)
        backupEnabled = c.value(.backupEnabled, backupEnabled)
        backupFolder = c.value(.backupFolder, backupFolder)
        notifyOnUpdate = c.value(.notifyOnUpdate, notifyOnUpdate)
        internalCIDRs = c.value(.internalCIDRs, internalCIDRs)
    }
}

extension AppConfig {
    enum CodingKeys: String, CodingKey {
        case settings, hosts, version, lastNotifiedUpdate
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = c.value(.settings, settings)
        hosts = c.value(.hosts, hosts)
        version = c.value(.version, version)
        lastNotifiedUpdate = c.value(.lastNotifiedUpdate, lastNotifiedUpdate)
    }
}
