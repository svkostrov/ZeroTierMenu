import Foundation

struct MobileNetworkHost: Identifiable, Equatable {
    let id: String
    let name: String
    let resolvedName: String?
    let ipv4Addresses: [String]
    let isOnline: Bool
    let lastSeenText: String?
    let operatingSystem: String?
}
