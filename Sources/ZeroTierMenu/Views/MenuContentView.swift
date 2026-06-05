import AppKit
import SwiftUI

struct MenuContentView: View {
    @Bindable var store: NetworkStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            scanSection
            statusSection
            hostList
            manualHostSection
            footerSection
        }
        .padding(16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                            Text("Этот Mac: \(localIPv4)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let subnetCIDR = network.subnet {
                            Text("Подсеть: \(subnetCIDR)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let network = store.networks.first {
                if let localIPv4 = network.ipv4 {
                    Text("Этот Mac: \(localIPv4)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let subnetCIDR = network.subnet {
                    Text("Подсеть: \(subnetCIDR)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var scanSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("Сканировать сеть") {
                    Task {
                        await store.refreshHosts()
                    }
                }
                .disabled(store.isLoading)

                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.hosts) { host in
                            HostRowView(
                                host: host,
                                initialAlias: store.alias(for: host),
                                copyAction: { ipv4 in
                                    store.copyIPv4(ipv4)
                                },
                                saveAliasAction: { alias in
                                    store.saveAlias(alias, for: host)
                                },
                                removeManualHostAction: {
                                    store.removeManualHost(host)
                                }
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360, maxHeight: .infinity, alignment: .topLeading)
    }

    private var manualHostSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Добавить хост вручную")
                .font(.subheadline.weight(.medium))

            HStack(spacing: 8) {
                TextField("IPv4 адрес", text: $store.manualHostIPDraft)
                    .textFieldStyle(.roundedBorder)

                TextField("Имя хоста", text: $store.manualHostNameDraft)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Добавить") {
                    store.addManualHost()
                    Task {
                        await store.refreshHosts()
                    }
                }
                .disabled(store.manualHostIPDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
        }
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
