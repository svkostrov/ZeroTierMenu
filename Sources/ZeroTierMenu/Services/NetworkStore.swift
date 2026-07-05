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
    var launchAtLoginEnabled = false
    var autoScanEnabled = true
    var centralSessionState: CentralSessionState = .unknown

    var emptyStateDescription: String {
        if isLoading {
            return "Получаю список хостов из ZeroTier Central..."
        }
        return "Пока не удалось получить список хостов из ZeroTier Central."
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

    var centralBrowserURLText: String? {
        centralSession.currentURL?.absoluteString
    }

    /// Список растёт вместе с хостами; прокрутка появляется от 11 хостов и больше.
    private let maxVisibleHostRows = 10

    var hostListHeight: CGFloat {
        let rowHeight: CGFloat = 58
        let rowSpacing: CGFloat = 6
        let emptyHeight: CGFloat = 140

        if hosts.isEmpty {
            return emptyHeight
        }

        let rows = CGFloat(min(hosts.count, maxVisibleHostRows))
        return (rows * rowHeight) + (max(rows - 1, 0) * rowSpacing)
    }

    var popupHeight: CGFloat {
        var topAndBottomChromeHeight: CGFloat = 185
        if hasMultipleNetworks {
            topAndBottomChromeHeight += 30 + (CGFloat(networks.count) * 34)
        }
        return topAndBottomChromeHeight + hostListHeight
    }

    private var didBootstrap = false
    private var autoScanTask: Task<Void, Never>?
    private var lastScanAt: Date?
    private let localService = LocalZeroTierService()
    private let scanner = NetworkScannerService()
    private let aliasStore = HostAliasStore()
    private let launchAtLoginService = LaunchAtLoginService()
    private let configStore = AppConfigStore()
    private var centralAuthWindowController: CentralAuthWindowController?
    let centralSession = CentralBrowserSession()

    init() {
        let config = configStore.loadConfig()
        autoScanEnabled = config.autoScanEnabled
        hostAliases = aliasStore.loadAliases()
        launchAtLoginEnabled = launchAtLoginService.isEnabled()
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        centralSession.onNavigationFinished = { [weak self] url in
            self?.handleCentralNavigationFinished(url: url)
        }
        await loadLocalNetworkContext()
        await autoLoginAndRefresh()
        startAutoScanLoopIfNeeded()
    }

    private func autoLoginAndRefresh() async {
        setStatus("Восстанавливаю сессию Central...", isError: false)
        await refreshHosts()
        if centralSessionState == .needsLogin {
            showCentralAuthWindow()
        }
    }

    private func handleCentralNavigationFinished(url: URL?) {
        guard let host = url?.host, host.contains("central.zerotier.com") else { return }
        guard centralSessionState != .authenticated, !isLoading else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshHosts()
            if self.centralSessionState == .authenticated {
                self.closeCentralAuthWindow()
            }
        }
    }

    private func ensureCentralPageLoaded() async {
        guard !centralSession.isOnCentralPage else { return }
        await centralSession.loadAndWaitForPage(networkID: selectedNetworkContext?.networkID)
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

    func menuDidAppear() async {
        guard !isLoading else { return }
        let lastScan = lastScanAt ?? .distantPast
        guard Date().timeIntervalSince(lastScan) >= 10 else { return }
        await refreshHosts()
    }

    func refreshHosts() async {
        guard !isLoading else { return }
        await refreshHostsFromCentral()
    }

    private func refreshHostsFromCentral() async {
        guard let selectedNetwork = selectedNetworkContext else {
            hosts = []
            setStatus("Сначала нужно выбрать локальную ZeroTier сеть.", isError: true)
            return
        }

        isLoading = true
        defer {
            isLoading = false
            lastScanAt = Date()
        }

        do {
            await ensureCentralPageLoaded()
            let members = try await centralSession.fetchMembers(networkID: selectedNetwork.networkID)
            centralSessionState = .authenticated
            let allIPs = Array(Set(members.flatMap(\.ipv4Addresses))).sorted()
            let statuses = await scanner.reachability(hostIPs: allIPs)

            hosts = members
                .filter { !$0.ipv4Addresses.isEmpty }
                .map { member in
                    let preferredName = hostAliases[member.id]
                        ?? member.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let fallbackName = preferredName?.isEmpty == false ? preferredName! : (member.ipv4Addresses.first ?? member.id)

                    return NetworkHost(
                        id: member.id,
                        networkID: selectedNetwork.networkID,
                        networkName: selectedNetwork.name,
                        displayName: fallbackName,
                        resolvedName: member.name,
                        ipv4Addresses: member.ipv4Addresses,
                        isOnline: member.ipv4Addresses.contains { statuses[$0] == true },
                        lastActiveText: formattedLastActive(member.lastSeenTime),
                        operatingSystem: member.operatingSystem?.uppercased()
                    )
                }
                .sorted {
                    if $0.isOnline != $1.isOnline {
                        return $0.isOnline && !$1.isOnline
                    }
                    return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }

            setStatus("Получено хостов из Central: \(hosts.count)", isError: false)
        } catch {
            hosts = []
            if case CentralBrowserSessionError.unauthorized = error {
                centralSessionState = .needsLogin
            } else {
                centralSessionState = .unknown
            }
            setStatus("Не удалось получить хосты из Central: \(error.localizedDescription)", isError: true)
            await writeCentralDiagnostics(networkID: selectedNetwork.networkID)
        }
    }

    private func writeCentralDiagnostics(networkID: String) async {
        let report = await centralSession.collectDiagnostics(networkID: networkID)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZeroTierMenu", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("central_debug.json")
        try? report.write(to: fileURL, atomically: true, encoding: .utf8)
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
        return ""
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
                networkID: currentHost.networkID,
                networkName: currentHost.networkName,
                displayName: preferredDisplayName(for: currentHost),
                resolvedName: currentHost.resolvedName,
                ipv4Addresses: currentHost.ipv4Addresses,
                isOnline: currentHost.isOnline,
                lastActiveText: currentHost.lastActiveText,
                operatingSystem: currentHost.operatingSystem
            )
        }
        setStatus(trimmed.isEmpty ? "Пользовательское имя удалено." : "Имя хоста сохранено.", isError: false)
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
        setStatus(enabled ? "Автообновление включено." : "Автообновление выключено.", isError: false)
    }

    func loadCentralLoginPage() {
        centralSession.loadLogin(networkID: selectedNetworkContext?.networkID)
    }

    func reloadCentralLoginPage() {
        if let networkID = selectedNetworkContext?.networkID {
            centralSession.reloadNetwork(networkID: networkID)
        } else {
            centralSession.loadLogin(networkID: nil)
        }
    }

    func clearCentralSession() async {
        await centralSession.clearSession()
        centralSessionState = .needsLogin
        hosts = []
        setStatus("Сессия Central сброшена.", isError: false)
        showCentralAuthWindow()
        loadCentralLoginPage()
    }

    func showCentralAuthWindow() {
        if centralAuthWindowController == nil {
            centralAuthWindowController = CentralAuthWindowController(store: self)
        }
        centralAuthWindowController?.show()
    }

    func closeCentralAuthWindow() {
        centralAuthWindowController?.close()
    }

    func centralAuthWindowDidClose() {
        centralAuthWindowController = nil
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
        return host.resolvedName ?? host.ipv4Addresses.first ?? host.id
    }

    private func formattedLastActive(_ rawValue: String?) -> String? {
        guard let rawValue,
              !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackISOFormatter = ISO8601DateFormatter()
        fallbackISOFormatter.formatOptions = [.withInternetDateTime]

        let date = isoFormatter.date(from: rawValue) ?? fallbackISOFormatter.date(from: rawValue)
        guard let date else { return rawValue }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM HH:mm"
        return formatter.string(from: date)
    }
}
