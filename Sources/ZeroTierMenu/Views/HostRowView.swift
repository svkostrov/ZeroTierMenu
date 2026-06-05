import SwiftUI

struct HostRowView: View {
    let host: NetworkHost
    let initialAlias: String
    let copyAction: (String) -> Void
    let saveAliasAction: (String) -> Void
    let removeManualHostAction: () -> Void
    @State private var aliasDraft: String

    init(
        host: NetworkHost,
        initialAlias: String,
        copyAction: @escaping (String) -> Void,
        saveAliasAction: @escaping (String) -> Void,
        removeManualHostAction: @escaping () -> Void
    ) {
        self.host = host
        self.initialAlias = initialAlias
        self.copyAction = copyAction
        self.saveAliasAction = saveAliasAction
        self.removeManualHostAction = removeManualHostAction
        _aliasDraft = State(initialValue: initialAlias)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(host.isOnline ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)

                Text(host.displayName)
                    .font(.subheadline.weight(.medium))

                if host.isManual {
                    Text("manual")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()
                if !host.isOnline {
                    Text("offline")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let networkName = host.networkName, !networkName.isEmpty {
                Text(networkName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let networkID = host.networkID, !networkID.isEmpty {
                Text(networkID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            ForEach(host.ipv4Addresses, id: \.self) { address in
                Button {
                    copyAction(address)
                } label: {
                    HStack {
                        Text(address)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Задать имя вручную", text: $aliasDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        saveAliasAction(aliasDraft)
                    }

                HStack {
                    if host.resolvedName != nil {
                        Button("Сбросить") {
                            aliasDraft = ""
                            saveAliasAction("")
                        }
                        .disabled(initialAlias.isEmpty)
                    }

                    if host.isManual {
                        Button("Удалить хост") {
                            removeManualHostAction()
                        }
                    }

                    Spacer()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: initialAlias) { _, newValue in
            aliasDraft = newValue
        }
    }
}
