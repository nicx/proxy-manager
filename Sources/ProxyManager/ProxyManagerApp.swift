import SwiftUI

struct ProxyManagerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        // Filled circle when Caddy is running, outline when stopped.
        MenuBarExtra("ProxyManager",
                     systemImage: model.caddyRunning ? "arrow.left.arrow.right.circle.fill"
                                                      : "arrow.left.arrow.right.circle") {
            MainView()
                .environmentObject(model)
                .frame(width: 480, height: 560)
        }
        .menuBarExtraStyle(.window)
    }
}
