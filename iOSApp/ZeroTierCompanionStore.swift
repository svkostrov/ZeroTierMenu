import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ZeroTierCompanionStore {
    var savedNetworkIDs: [String]
    var selectedNetworkID: String
    var apiToken: String
    var hosts: [MobileNetworkHost] = []
    var hostAliases: [String: String]
    var isLoading = false
    var statusMessage = ""
    var statusIsError = false
    var lastCopiedIPv4: String?
    var isAuthSheetPresented = false
    var centralSessionState: CentralSessionState = .unknown

    let centralSession = MobileCentralSession()

    private let configStore = MobileConfigStore()

    init() {
        let config = configStore.loadConfig()
        savedNetworkIDs = config.savedNetworkIDs
        selectedNetworkID = config.selectedNetworkID.isEmpty ? (config.savedNetworkIDs.first ?? "") : config.selectedNetworkID
        apiToken = config.apiToken
        hostAliases = config.hostAliases
    }

    func bootstrap() async {
        await refreshCentralSessionState()
    }

    func refreshCentralSessionState() async {
        if !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            centralSessionState = .authenticated
        } else {
            centralSessionState = await centralSession.hasCentralCookies() ? .authenticated : .needsLogin
        }
    }

    func presentLogin() {
        centralSession.rebuildWebView()
        isAuthSheetPresented = true
        if selectedNetworkID.isEmpty {
            centralSession.loadLogin()
        } else {
            centralSession.loadNetwork(selectedNetworkID)
        }
    }

    func refreshHosts() async {
        let trimmedNetworkID = selectedNetworkID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNetworkID.isEmpty else {
            setStatus("Добавьте network ID.", isError: true)
            return
        }
        guard !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let members: [MobileCentralMemberRecord]
            if !trimmedToken.isEmpty {
                members = try await centralSession.fetchMembers(networkID: trimmedNetworkID, apiToken: trimmedToken)
            } else {
                members = try await centralSession.fetchMembers(networkID: trimmedNetworkID)
            }
            centralSessionState = .authenticated
            hosts = members
                .filter { !$0.ipv4Addresses.isEmpty }
                .map { member in
                    let preferredName = hostAliases[member.id]
                        ?? member.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayName = preferredName?.isEmpty == false ? preferredName! : (member.ipv4Addresses.first ?? member.id)

                    return MobileNetworkHost(
                        id: member.id,
                        name: displayName,
                        resolvedName: member.name,
                        ipv4Addresses: member.ipv4Addresses,
                        isOnline: member.isOnline,
                        lastSeenText: formatLastSeen(member.lastSeenTime),
                        operatingSystem: member.operatingSystem?.uppercased()
                    )
                }
                .sorted {
                    if $0.isOnline != $1.isOnline {
                        return $0.isOnline && !$1.isOnline
                    }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }

            persist()
            setStatus("Получено хостов: \(hosts.count)", isError: false)
        } catch {
            hosts = []
            centralSessionState = .needsLogin
            setStatus(error.localizedDescription, isError: true)
        }
    }

    func addNetwork(_ networkID: String) {
        let trimmed = networkID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !savedNetworkIDs.contains(trimmed) else {
            selectedNetworkID = trimmed
            persist()
            return
        }
        savedNetworkIDs.append(trimmed)
        savedNetworkIDs.sort()
        selectedNetworkID = trimmed
        persist()
        setStatus("Сеть добавлена.", isError: false)
    }

    func removeSelectedNetwork() {
        guard !selectedNetworkID.isEmpty else { return }
        savedNetworkIDs.removeAll { $0 == selectedNetworkID }
        selectedNetworkID = savedNetworkIDs.first ?? ""
        hosts = []
        persist()
        setStatus("Сеть удалена.", isError: false)
    }

    func setSelectedNetworkID(_ networkID: String) {
        selectedNetworkID = networkID
        persist()
    }

    func copyIPv4(_ ipv4: String) {
        UIPasteboard.general.string = ipv4
        lastCopiedIPv4 = ipv4
        setStatus("IP скопирован.", isError: false)
    }

    func alias(for host: MobileNetworkHost) -> String {
        hostAliases[host.id] ?? ""
    }

    func saveAlias(_ alias: String, for host: MobileNetworkHost) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            hostAliases.removeValue(forKey: host.id)
        } else {
            hostAliases[host.id] = trimmed
        }

        hosts = hosts.map { currentHost in
            guard currentHost.id == host.id else { return currentHost }
            return MobileNetworkHost(
                id: currentHost.id,
                name: trimmed.isEmpty ? (currentHost.resolvedName?.isEmpty == false ? currentHost.resolvedName! : (currentHost.ipv4Addresses.first ?? currentHost.id)) : trimmed,
                resolvedName: currentHost.resolvedName,
                ipv4Addresses: currentHost.ipv4Addresses,
                isOnline: currentHost.isOnline,
                lastSeenText: currentHost.lastSeenText,
                operatingSystem: currentHost.operatingSystem
            )
        }
        persist()
        setStatus(trimmed.isEmpty ? "Алиас удалён." : "Алиас сохранён.", isError: false)
    }

    func clearSession() async {
        await centralSession.clearSession()
        centralSessionState = .needsLogin
        hosts = []
        setStatus("Сессия сброшена.", isError: false)
    }

    func saveAPIToken(_ token: String) {
        apiToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
        centralSessionState = apiToken.isEmpty ? .needsLogin : .authenticated
        setStatus(apiToken.isEmpty ? "API token удалён." : "API token сохранён.", isError: false)
    }

    private func persist() {
        configStore.saveConfig(
            ZeroTierMobileConfig(
                hostAliases: hostAliases,
                savedNetworkIDs: savedNetworkIDs,
                selectedNetworkID: selectedNetworkID,
                apiToken: apiToken
            )
        )
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    private func formatLastSeen(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if let interval = TimeInterval(value) {
            let date = Date(timeIntervalSince1970: interval)
            return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        }
        if let date = ISO8601DateFormatter().date(from: value) {
            return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        }
        return value
    }
}

enum CentralSessionState: Equatable {
    case unknown
    case authenticated
    case needsLogin

    var title: String {
        switch self {
        case .unknown:
            return "Сессия Central: неизвестно"
        case .authenticated:
            return "Сессия Central: активна"
        case .needsLogin:
            return "Сессия Central: нужен вход"
        }
    }
}
