import Foundation

struct HostAliasStore {
    private let key = "hostAliases"
    private let defaults = UserDefaults.standard

    func loadAliases() -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    func saveAliases(_ aliases: [String: String]) {
        defaults.set(aliases, forKey: key)
    }
}
