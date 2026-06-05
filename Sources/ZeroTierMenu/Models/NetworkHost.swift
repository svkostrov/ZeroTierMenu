import Foundation

struct NetworkHost: Identifiable, Equatable {
    let id: String
    let displayName: String
    let resolvedName: String?
    let ipv4Addresses: [String]
    let isOnline: Bool
    let isManual: Bool
}
