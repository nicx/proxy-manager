import SwiftUI

struct ProxyManagerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        // Always the outline glyph, regardless of running state.
        MenuBarExtra("ProxyManager", systemImage: "checkmark.shield") {
            MainView()
                .environmentObject(model)
                .frame(width: 480, height: 560)
        }
        .menuBarExtraStyle(.window)
    }
}
