import AppKit
import SwiftUI

@MainActor
final class CentralAuthWindowController: NSWindowController, NSWindowDelegate {
    private weak var store: NetworkStore?

    init(store: NetworkStore) {
        self.store = store

        let contentView = CentralAuthWindowView(store: store)
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ZeroTier Central Login"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        guard let window else { return }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        store?.centralAuthWindowDidClose()
    }
}
