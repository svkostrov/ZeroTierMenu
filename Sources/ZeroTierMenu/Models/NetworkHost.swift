import Foundation

struct NetworkHost: Identifiable, Equatable {
    let id: String
    let networkID: String?
    let networkName: String?
    let displayName: String
    let resolvedName: String?
    let ipv4Addresses: [String]
    let isOnline: Bool
    let lastActiveText: String?
    let operatingSystem: String?
}
