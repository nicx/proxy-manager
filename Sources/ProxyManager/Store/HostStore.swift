import Foundation

/// Loads and persists the full app configuration (settings + host list) as JSON
/// in `~/Library/Application Support/ProxyManager/config.json`.
enum HostStore {
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: AppPaths.configStore) else {
            return AppConfig()
        }
        return (try? JSONDecoder().decode(AppConfig.self, from: data)) ?? AppConfig()
    }

    static func save(_ config: AppConfig) throws {
        try AppPaths.ensureDirectories()
        let data = try encoder.encode(config)
        try data.write(to: AppPaths.configStore, options: .atomic)
    }
}
