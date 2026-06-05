import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class NetworkStore {
    var networks: [LocalNetworkContext] = []
    var selectedNetworkIDForUI = ""
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
    var autoScanEnabled = true

    var emptyStateDescription: String {
        if isLoading {
            return "Сканирую ZeroTier-сети..."
        }
        return "Не нашёл живые хосты или не удалось определить активные ZeroTier-сети."
    }

    var primaryNetworkLabel: String {
        guard let network = networks.first else { return "" }
        return network.name.isEmpty ? network.networkID : network.name
    }

    var selectedNetworkContext: LocalNetworkContext? {
        if let selected = networks.first(where: { $0.networkID == selectedNetworkIDForUI }) {
            return selected
        }
        return networks.first
    }

    var hasMultipleNetworks: Bool {
        networks.count > 1
    }

    private var didBootstrap = false
    private var autoScanTask: Task<Void, Never>?
    private var lastScanAt: Date?
    private let localService = LocalZeroTierService()
    private let scanner = NetworkScannerService()
    private let aliasStore = HostAliasStore()
    private let manualHostStore = ManualHostStore()
    private let launchAtLoginService = LaunchAtLoginService()
    private let configStore = AppConfigStore()

    init() {
        let config = configStore.loadConfig()
        autoScanEnabled = config.autoScanEnabled
        hostAliases = aliasStore.loadAliases()
        manualHosts = manualHostStore.loadHosts()
        launchAtLoginEnabled = launchAtLoginService.isEnabled()
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await loadLocalNetworkContext()
        await refreshIfPossible()
        startAutoScanLoopIfNeeded()
    }

    func loadLocalNetworkContext() async {
        let loadedNetworks = await localService.loadNetworkContexts()
        guard !loadedNetworks.isEmpty else {
            networks = []
            setStatus("Не удалось прочитать локальные параметры ZeroTier.", isError: true)
            return
        }

        networks = loadedNetworks.sorted {
            let left = $0.name.isEmpty ? $0.networkID : $0.name
            let right = $1.name.isEmpty ? $1.networkID : $1.name
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }

        if selectedNetworkIDForUI.isEmpty || !networks.contains(where: { $0.networkID == selectedNetworkIDForUI }) {
            selectedNetworkIDForUI = networks.first?.networkID ?? ""
        }
    }

    func refreshIfPossible() async {
        await refreshHosts()
    }

    func refreshHosts() async {
        guard !isLoading else { return }

        let scannableNetworks = networks.filter { network in
            guard let subnet = network.subnet else { return false }
            return !subnet.isEmpty
        }

        guard !scannableNetworks.isEmpty else {
            hosts = []
            setStatus("Не удалось определить подсети активных ZeroTier-сетей.", isError: true)
            return
        }

        isLoading = true
        defer {
            isLoading = false
            lastScanAt = Date()
        }

        var scannedHosts: [NetworkHost] = []
        for network in scannableNetworks {
            guard let subnetCIDR = network.subnet else { continue }
            let foundHosts = await scanner.scan(
                subnetCIDR: subnetCIDR,
                excluding: network.ipv4,
                networkID: network.networkID,
                networkName: network.name
            )
            scannedHosts.append(contentsOf: foundHosts)
        }

        let manualOnlyIPs = manualHosts
            .map(\.ip)
            .filter { ip in !scannedHosts.contains(where: { $0.ipv4Addresses.contains(ip) }) }
        let probedManualHosts = await scanner.probe(hostIPs: manualOnlyIPs)

        var mergedHosts = Dictionary(uniqueKeysWithValues: scannedHosts.map { ($0.id, $0) })
        for host in probedManualHosts {
            mergedHosts[host.id] = host
        }

        hosts = mergedHosts.values
            .map { host in
                NetworkHost(
                    id: host.id,
                    networkID: host.networkID,
                    networkName: host.networkName,
                    displayName: preferredDisplayName(for: host),
                    resolvedName: host.resolvedName,
                    ipv4Addresses: host.ipv4Addresses,
                    isOnline: host.isOnline,
                    isManual: host.isManual || manualHosts.contains(where: { $0.ip == host.ipv4Addresses.first })
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
        if let alias = hostAliases[host.id] {
            return alias
        }
        if let ip = host.ipv4Addresses.first,
           let manualName = manualHosts.first(where: { $0.ip == ip })?.name {
            return manualName
        }
        return ""
    }

    func saveAlias(_ alias: String, for host: NetworkHost) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostIP = host.ipv4Addresses.first

        if trimmed.isEmpty {
            hostAliases.removeValue(forKey: host.id)
        } else {
            hostAliases[host.id] = trimmed
        }
        aliasStore.saveAliases(hostAliases)

        if host.isManual, let hostIP {
            manualHosts = manualHosts.map { currentHost in
                guard currentHost.ip == hostIP else { return currentHost }
                return SavedManualHost(ip: currentHost.ip, name: trimmed)
            }
            manualHostStore.saveHosts(manualHosts)
        }

        hosts = hosts.map { currentHost in
            guard currentHost.id == host.id else { return currentHost }
            return NetworkHost(
                id: currentHost.id,
                networkID: currentHost.networkID,
                networkName: currentHost.networkName,
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
        let hostIP = host.ipv4Addresses.first ?? host.id
        manualHosts.removeAll { $0.ip == hostIP }
        manualHostStore.saveHosts(manualHosts)
        hosts = hosts.filter { currentHost in
            currentHost.id != host.id || !currentHost.isManual
        }
        setStatus("Ручной хост удалён.", isError: false)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginService.setEnabled(enabled)
            launchAtLoginEnabled = enabled
            setStatus(
                launchAtLoginEnabled ? "Автозапуск включён." : "Автозапуск выключен.",
                isError: false
            )
        } catch {
            launchAtLoginEnabled = launchAtLoginService.isEnabled()
            setStatus("Не удалось изменить автозапуск.", isError: true)
        }
    }

    func setAutoScanEnabled(_ enabled: Bool) {
        autoScanEnabled = enabled
        saveAutoScanSettings()
        setStatus(enabled ? "Автосканирование включено." : "Автосканирование выключено.", isError: false)
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    private var autoScanIntervalSeconds: Int {
        60
    }

    private func startAutoScanLoopIfNeeded() {
        guard autoScanTask == nil else { return }
        autoScanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard autoScanEnabled, !isLoading else { continue }
                let interval = TimeInterval(autoScanIntervalSeconds)
                let lastScan = lastScanAt ?? .distantPast
                guard Date().timeIntervalSince(lastScan) >= interval else { continue }
                await refreshHosts()
            }
        }
    }

    private func saveAutoScanSettings() {
        var config = configStore.loadConfig()
        config.autoScanEnabled = autoScanEnabled
        configStore.saveConfig(config)
    }

    private func preferredDisplayName(for host: NetworkHost) -> String {
        if let alias = hostAliases[host.id], !alias.isEmpty {
            return alias
        }
        if let hostIP = host.ipv4Addresses.first,
           let manualName = manualHosts.first(where: { $0.ip == hostIP })?.name,
           !manualName.isEmpty {
            return manualName
        }
        return host.resolvedName ?? host.ipv4Addresses.first ?? host.id
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
