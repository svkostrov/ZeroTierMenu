import Foundation

struct AppConfig: Codable {
    var hostAliases: [String: String] = [:]
    var manualHosts: [SavedManualHost] = []
}
