import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class NetworkStore {
    var networkID = "a581878f7d73f059"
    var networkName = "Rokot_net"
    var localIPv4: String?
    var subnetCIDR: String?
    var isLoading = false
    var statusMessage = ""
    var statusIsError = false
    var hosts: [NetworkHost] = []
    var lastCopiedIPv4: String?
    var hostAliases: [String: String] = [:]
    var manualHosts: [SavedManualHost] = []
    var manualHostIPDraft = ""
    var manualHostNameDraft = ""
    var launchAtLoginEnabled = false

    var emptyStateDescription: String {
        if isLoading {
            return "Сканирую ZeroTier-подсеть..."
        }
        return "Не нашёл живые хосты в подсети или не удалось определить диапазон сети."
    }

    private let localService = LocalZeroTierService()
    private let scanner = NetworkScannerService()
    private let aliasStore = HostAliasStore()
    private let manualHostStore = ManualHostStore()
    private let launchAtLoginService = LaunchAtLoginService()

    init() {
        hostAliases = aliasStore.loadAliases()
        manualHosts = manualHostStore.loadHosts()
        launchAtLoginEnabled = launchAtLoginService.isEnabled()
    }

    func loadLocalNetworkContext() async {
        guard let context = await localService.loadNetworkContext(networkID: networkID) else {
            setStatus("Не удалось прочитать локальные параметры ZeroTier.", isError: true)
            return
        }

        if !context.name.isEmpty {
            networkName = context.name
        }
        localIPv4 = context.ipv4
        subnetCIDR = context.subnet
    }

    func refreshIfPossible() async {
        await refreshHosts()
    }

    func refreshHosts() async {
        guard let subnetCIDR, !subnetCIDR.isEmpty else {
            setStatus("Не удалось определить подсеть ZeroTier.", isError: true)
            return
        }

        isLoading = true
        defer { isLoading = false }

        let scannedHosts = await scanner.scan(subnetCIDR: subnetCIDR, excluding: localIPv4)
        let manualOnlyIPs = manualHosts
            .map(\.ip)
            .filter { ip in !scannedHosts.contains(where: { $0.id == ip }) }
        let probedManualHosts = await scanner.probe(hostIPs: manualOnlyIPs)

        var mergedHosts = Dictionary(uniqueKeysWithValues: scannedHosts.map { ($0.id, $0) })
        for host in probedManualHosts {
            mergedHosts[host.id] = host
        }

        hosts = mergedHosts.values
            .map { host in
                NetworkHost(
                    id: host.id,
                    displayName: preferredDisplayName(for: host),
                    resolvedName: host.resolvedName,
                    ipv4Addresses: host.ipv4Addresses,
                    isOnline: host.isOnline,
                    isManual: manualHosts.contains(where: { $0.ip == host.id })
                )
            }
            .sorted {
                if $0.isOnline != $1.isOnline {
                    return $0.isOnline && !$1.isOnline
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        setStatus("Найдено живых хостов: \(hosts.count)", isError: false)
    }

    func copyIPv4(_ ipv4: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ipv4, forType: .string)
        lastCopiedIPv4 = ipv4
        setStatus("IPv4 адрес скопирован в буфер обмена.", isError: false)
    }

    func alias(for host: NetworkHost) -> String {
        hostAliases[host.id] ?? ""
    }

    func saveAlias(_ alias: String, for host: NetworkHost) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            hostAliases.removeValue(forKey: host.id)
        } else {
            hostAliases[host.id] = trimmed
        }
        aliasStore.saveAliases(hostAliases)
        hosts = hosts.map { currentHost in
            guard currentHost.id == host.id else { return currentHost }
            return NetworkHost(
                id: currentHost.id,
                displayName: preferredDisplayName(for: currentHost),
                resolvedName: currentHost.resolvedName,
                ipv4Addresses: currentHost.ipv4Addresses,
                isOnline: currentHost.isOnline,
                isManual: currentHost.isManual
            )
        }
        setStatus(trimmed.isEmpty ? "Пользовательское имя удалено." : "Имя хоста сохранено.", isError: false)
    }

    func addManualHost() {
        let ip = manualHostIPDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = manualHostNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        guard isValidIPv4(ip) else {
            setStatus("Введите корректный IPv4 адрес.", isError: true)
            return
        }

        if !manualHosts.contains(where: { $0.ip == ip }) {
            manualHosts.append(SavedManualHost(ip: ip, name: name))
        } else {
            manualHosts = manualHosts.map { host in
                host.ip == ip ? SavedManualHost(ip: ip, name: name) : host
            }
        }

        manualHosts.sort { $0.ip < $1.ip }
        manualHostStore.saveHosts(manualHosts)

        if !name.isEmpty {
            hostAliases[ip] = name
            aliasStore.saveAliases(hostAliases)
        }

        manualHostIPDraft = ""
        manualHostNameDraft = ""
        setStatus("Хост добавлен вручную.", isError: false)
    }

    func removeManualHost(_ host: NetworkHost) {
        manualHosts.removeAll { $0.ip == host.id }
        manualHostStore.saveHosts(manualHosts)
        hosts.removeAll { $0.id == host.id }
        setStatus("Ручной хост удалён.", isError: false)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginService.setEnabled(enabled)
            launchAtLoginEnabled = launchAtLoginService.isEnabled()
            setStatus(
                launchAtLoginEnabled ? "Автозапуск включён." : "Автозапуск выключен.",
                isError: false
            )
        } catch {
            launchAtLoginEnabled = launchAtLoginService.isEnabled()
            setStatus("Не удалось изменить автозапуск.", isError: true)
        }
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    private func preferredDisplayName(for host: NetworkHost) -> String {
        if let alias = hostAliases[host.id], !alias.isEmpty {
            return alias
        }
        if let manualName = manualHosts.first(where: { $0.ip == host.id })?.name,
           !manualName.isEmpty {
            return manualName
        }
        return host.resolvedName ?? host.id
    }

    private func isValidIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let octet = UInt8(part) else { return false }
            return String(octet) == part
        }
    }
}
