import Foundation

struct ManualHostStore {
    private let configStore = AppConfigStore()

    func loadHosts() -> [SavedManualHost] {
        configStore.loadConfig().manualHosts
    }

    func saveHosts(_ hosts: [SavedManualHost]) {
        var config = configStore.loadConfig()
        config.manualHosts = hosts
        configStore.saveConfig(config)
    }
}
