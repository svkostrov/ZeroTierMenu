import Foundation

struct AppConfig: Codable {
    var hostAliases: [String: String] = [:]
    var manualHosts: [SavedManualHost] = []
    var autoScanEnabled: Bool = true
    var autoScanHours: Int = 0
    var autoScanMinutes: Int = 1
    var autoScanSeconds: Int = 0
}
