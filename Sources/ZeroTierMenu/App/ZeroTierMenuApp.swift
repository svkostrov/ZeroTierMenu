import SwiftUI

@main
struct ZeroTierMenuApp: App {
    @State private var store = NetworkStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
                .frame(width: 410, height: 620)
                .task {
                    await store.loadLocalNetworkContext()
                    await store.refreshIfPossible()
                }
        } label: {
            Label("ZeroTier", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
                .frame(width: 480, height: 280)
        }
    }
}
