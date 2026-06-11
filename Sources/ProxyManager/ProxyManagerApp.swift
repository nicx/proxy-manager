import SwiftUI

struct ProxyManagerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        // Filled shield when Caddy is running, outline when stopped.
        MenuBarExtra("ProxyManager",
                     systemImage: model.caddyRunning ? "checkmark.shield.fill"
                                                      : "checkmark.shield") {
            MainView()
                .environmentObject(model)
                .frame(width: 480, height: 560)
        }
        .menuBarExtraStyle(.window)
    }
}
