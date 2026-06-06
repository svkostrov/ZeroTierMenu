import AppKit
import SwiftUI

struct MenuContentView: View {
    @Bindable var store: NetworkStore

    private var hostListHeight: CGFloat {
        if store.hosts.isEmpty {
            return 140
        }

        let rowHeight: CGFloat = 36
        let rowSpacing: CGFloat = 6
        let rows = CGFloat(store.hosts.count)
        return (rows * rowHeight) + (max(rows - 1, 0) * rowSpacing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            scanSection
            statusSection
            hostList
            footerSection
        }
        .padding(12)
        .onAppear {
            Task {
                await store.menuDidAppear()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(store.hasMultipleNetworks ? "ZeroTier Networks" : (store.primaryNetworkLabel.isEmpty ? "ZeroTier Network" : store.primaryNetworkLabel))
                .font(.headline)

            if store.hasMultipleNetworks {
                Picker("Сеть", selection: $store.selectedNetworkIDForUI) {
                    ForEach(store.networks) { network in
                        Text(network.name.isEmpty ? network.networkID : network.name)
                            .tag(network.networkID)
                    }
                }
                .pickerStyle(.menu)
            }

            if let selectedNetwork = store.selectedNetworkContext {
                Link(destination: URL(string: "https://central.zerotier.com/network/\(selectedNetwork.networkID)")!) {
                    Text(selectedNetwork.networkID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }

            if store.hasMultipleNetworks {
                ForEach(store.networks) { network in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(network.name.isEmpty ? network.networkID : network.name)
                            .font(.caption.weight(.medium))

                        if let localIPv4 = network.ipv4 {
                            Button("Ваш IP: \(localIPv4)") {
                                store.copyIPv4(localIPv4)
                            }
                            .buttonStyle(.plain)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let network = store.networks.first {
                if let localIPv4 = network.ipv4 {
                    Button("Ваш IP: \(localIPv4)") {
                        store.copyIPv4(localIPv4)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var scanSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Войти") {
                    store.showCentralAuthWindow()
                }
                .controlSize(.small)

                Button("Обновить") {
                    Task {
                        await store.refreshHosts()
                    }
                }
                .controlSize(.small)
                .disabled(store.isLoading)

                Button("Сбросить") {
                    Task {
                        await store.clearCentralSession()
                    }
                }
                .controlSize(.small)

                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Toggle("Авто", isOn: Binding(
                    get: { store.autoScanEnabled },
                    set: { newValue in
                        store.setAutoScanEnabled(newValue)
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.caption2)

                Spacer()
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(store.centralSessionState.title)
                .font(.caption)
                .foregroundStyle(store.centralSessionState == .needsLogin ? .orange : .secondary)

            if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(store.statusIsError ? .red : .secondary)
            }

            if let copiedIP = store.lastCopiedIPv4 {
                Text("Скопировано: \(copiedIP)")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private var hostList: some View {
        Group {
            if store.hosts.isEmpty {
                ContentUnavailableView(
                    "Хостов пока нет",
                    systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                    description: Text(store.emptyStateDescription)
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(store.hosts) { host in
                            HostRowView(
                                host: host,
                                initialAlias: store.alias(for: host),
                                copyAction: { ipv4 in
                                    store.copyIPv4(ipv4)
                                },
                                saveAliasAction: { alias in
                                    store.saveAlias(alias, for: host)
                                }
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: hostListHeight, idealHeight: hostListHeight, maxHeight: hostListHeight, alignment: .topLeading)
    }

    private var footerSection: some View {
        HStack {
            Toggle("Автозапуск", isOn: Binding(
                get: { store.launchAtLoginEnabled },
                set: { newValue in
                    store.setLaunchAtLogin(newValue)
                }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)

            Spacer()

            Button("Выход") {
                NSApp.terminate(nil)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
        .font(.caption)
    }
}
