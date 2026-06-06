import Foundation

struct AppConfig: Codable {
    var hostAliases: [String: String] = [:]
    var autoScanEnabled: Bool = true
}
