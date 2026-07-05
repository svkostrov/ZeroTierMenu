import Foundation

struct MobileConfigStore {
    private let fileManager = FileManager.default

    func loadConfig() -> ZeroTierMobileConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(ZeroTierMobileConfig.self, from: data) else {
            return ZeroTierMobileConfig()
        }
        return config
    }

    func saveConfig(_ config: ZeroTierMobileConfig) {
        do {
            try ensureConfigDirectoryExists()
            let data = try JSONEncoder.pretty.encode(config)
            try data.write(to: configURL, options: .atomic)
        } catch {
            NSLog("ZeroTierCompanion: failed to save config: \(error.localizedDescription)")
        }
    }

    private var configURL: URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())

        return baseDirectory
            .appendingPathComponent("ZeroTierCompanion", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    private func ensureConfigDirectoryExists() throws {
        try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
