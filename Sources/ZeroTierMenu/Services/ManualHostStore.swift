import Foundation

struct ManualHostStore {
    private let key = "manualHosts"
    private let defaults = UserDefaults.standard

    func loadHosts() -> [SavedManualHost] {
        guard let data = defaults.data(forKey: key),
              let hosts = try? JSONDecoder().decode([SavedManualHost].self, from: data) else {
            return []
        }
        return hosts
    }

    func saveHosts(_ hosts: [SavedManualHost]) {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        defaults.set(data, forKey: key)
    }
}
