import Foundation

struct AppConfigStore {
    private let fileManager = FileManager.default
    private let defaults = UserDefaults.standard
    private let legacyAliasesKey = "hostAliases"

    func loadConfig() -> AppConfig {
        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return config
        }

        let migrated = AppConfig(
            hostAliases: defaults.dictionary(forKey: legacyAliasesKey) as? [String: String] ?? [:]
        )

        saveConfig(migrated)

        return migrated
    }

    func saveConfig(_ config: AppConfig) {
        do {
            try ensureConfigDirectoryExists()
            let data = try JSONEncoder.pretty.encode(config)
            try data.write(to: configURL, options: .atomic)
        } catch {
            NSLog("ZeroTierMenu: failed to save config: \(error.localizedDescription)")
        }
    }

    var configURL: URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)

        return baseDirectory
            .appendingPathComponent("ZeroTierMenu", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    private func ensureConfigDirectoryExists() throws {
        let directoryURL = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
