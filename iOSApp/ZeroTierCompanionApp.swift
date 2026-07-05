import SwiftUI

@main
struct ZeroTierCompanionApp: App {
    @State private var store = ZeroTierCompanionStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
    }
}
