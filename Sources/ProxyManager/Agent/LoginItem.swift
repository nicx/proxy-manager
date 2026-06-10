import Foundation
import ServiceManagement

/// Controls whether the ProxyManager *app* itself launches at login (the menu-bar
/// UI). Note: the Caddy proxy runs independently via its own LaunchAgent and
/// already starts at login regardless of this setting.
enum LoginItem {
    /// Whether launch-at-login is currently enabled.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Login items only work for a real, code-signed .app bundle — not for a raw
    /// `swift run` executable. Used to disable the toggle in dev builds.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}
