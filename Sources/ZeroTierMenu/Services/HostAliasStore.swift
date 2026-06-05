import Foundation

struct HostAliasStore {
    private let configStore = AppConfigStore()

    func loadAliases() -> [String: String] {
        configStore.loadConfig().hostAliases
    }

    func saveAliases(_ aliases: [String: String]) {
        var config = configStore.loadConfig()
        config.hostAliases = aliases
        configStore.saveConfig(config)
    }
}
