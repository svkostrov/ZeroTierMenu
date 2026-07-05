import SwiftUI

struct RootView: View {
    @Bindable var store: ZeroTierCompanionStore
    @State private var networkDraft = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                hostList
            }
            .navigationTitle("ZeroTier")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.presentLogin()
                    } label: {
                        Label("Войти", systemImage: "person.crop.circle")
                    }
                }
            }
        }
        .task {
            await store.bootstrap()
        }
        .sheet(isPresented: $store.isAuthSheetPresented) {
            AuthSheetView(store: store)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iOS companion для ZeroTier Central")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Network ID", text: $networkDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                Button("Добавить") {
                    store.addNetwork(networkDraft)
                    networkDraft = ""
                }
                .buttonStyle(.borderedProminent)
            }

            if !store.savedNetworkIDs.isEmpty {
                Picker("Сеть", selection: Binding(
                    get: { store.selectedNetworkID },
                    set: { store.setSelectedNetworkID($0) }
                )) {
                    ForEach(store.savedNetworkIDs, id: \.self) { networkID in
                        Text(networkID).tag(networkID)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack(spacing: 8) {
                Button("Обновить") {
                    Task {
                        await store.refreshHosts()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isLoading)

                Button("Сбросить сессию") {
                    Task {
                        await store.clearSession()
                    }
                }
                .buttonStyle(.bordered)

                Button("Удалить сеть") {
                    store.removeSelectedNetwork()
                }
                .buttonStyle(.bordered)
                .disabled(store.selectedNetworkID.isEmpty)

                if store.isLoading {
                    ProgressView()
                }
            }

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
        .padding(16)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.94, green: 0.97, blue: 1.0),
                    Color(red: 0.98, green: 0.98, blue: 0.99)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var hostList: some View {
        Group {
            if store.hosts.isEmpty {
                ContentUnavailableView(
                    "Хостов пока нет",
                    systemImage: "network.slash",
                    description: Text("Добавьте network ID и API token ZeroTier Central, затем нажмите «Обновить».")
                )
            } else {
                List(store.hosts) { host in
                    MobileHostRowView(
                        host: host,
                        initialAlias: store.alias(for: host),
                        copyAction: store.copyIPv4,
                        saveAliasAction: { alias in
                            store.saveAlias(alias, for: host)
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
            }
        }
    }
}
