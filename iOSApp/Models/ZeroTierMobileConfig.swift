import Foundation

struct ZeroTierMobileConfig: Codable {
    var hostAliases: [String: String] = [:]
    var savedNetworkIDs: [String] = []
    var selectedNetworkID: String = ""
    var apiToken: String = ""
}
