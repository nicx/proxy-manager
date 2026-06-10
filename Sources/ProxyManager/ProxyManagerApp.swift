import SwiftUI

struct ProxyManagerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("ProxyManager", systemImage: model.caddyRunning ? "lock.shield.fill" : "lock.shield") {
            MainView()
                .environmentObject(model)
                .frame(width: 480, height: 560)
        }
        .menuBarExtraStyle(.window)
    }
}
