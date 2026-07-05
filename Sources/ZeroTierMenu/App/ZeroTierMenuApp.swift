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
                .frame(width: 335, height: store.popupHeight, alignment: .top)
                .task {
                    await store.bootstrap()
                }
        } label: {
            MenuBarIconView(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
                .frame(width: 480, height: 280)
        }
    }
}

private struct MenuBarIconView: View {
    var store: NetworkStore

    var body: some View {
        Image(nsImage: menuBarIcon(dimmed: store.centralSessionState != .authenticated))
    }

    private func menuBarIcon(dimmed: Bool) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let symbol = NSImage(
            systemSymbolName: "point.3.connected.trianglepath.dotted",
            accessibilityDescription: "ZeroTier"
        )?.withSymbolConfiguration(configuration) ?? NSImage()

        guard dimmed else {
            symbol.isTemplate = true
            return symbol
        }

        let dimmedImage = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.35)
            return true
        }
        dimmedImage.isTemplate = true
        return dimmedImage
    }
}
