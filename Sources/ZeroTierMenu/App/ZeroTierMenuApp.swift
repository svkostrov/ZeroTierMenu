import AppKit
import SwiftUI

final class ZeroTierMenuAppDelegate: NSObject, NSApplicationDelegate {
    var store: NetworkStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let store else { return }
        Task { @MainActor in
            await store.bootstrap()
        }
    }
}

@main
struct ZeroTierMenuApp: App {
    private let store = NetworkStore()
    @NSApplicationDelegateAdaptor private var appDelegate: ZeroTierMenuAppDelegate

    init() {
        appDelegate.store = store
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
                .frame(width: 335, height: 620)
                .task {
                    await store.bootstrap()
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
