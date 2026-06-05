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
        _aliasDraft = State(initialValue: initialAlias.isEmpty ? host.displayName : initialAlias)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(host.isOnline ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)

                TextField("Имя хоста", text: $aliasDraft)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    )
                    .onSubmit {
                        saveAliasAction(aliasDraft)
                    }

                Spacer()

                if let primaryAddress = host.ipv4Addresses.first {
                    Button {
                        copyAction(primaryAddress)
                    } label: {
                        HStack(spacing: 5) {
                            Text(primaryAddress)
                                .font(.system(.caption2, design: .monospaced))
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if !host.isOnline {
                    Text("offline")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if let networkName = host.networkName, !networkName.isEmpty {
                    Text(networkName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let networkID = host.networkID, !networkID.isEmpty {
                    Text(networkID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if host.isManual {
                    Text("manual")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(Array(host.ipv4Addresses.dropFirst()), id: \.self) { address in
                Button {
                    copyAction(address)
                } label: {
                    HStack {
                        Text(address)
                            .font(.system(.caption2, design: .monospaced))
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if host.resolvedName != nil {
                    Button("Сбросить") {
                        aliasDraft = host.displayName
                        saveAliasAction("")
                    }
                    .controlSize(.small)
                    .disabled(initialAlias.isEmpty)
                }

                if host.isManual {
                    Button("Удалить хост") {
                        removeManualHostAction()
                    }
                    .controlSize(.small)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: initialAlias) { _, newValue in
            aliasDraft = newValue.isEmpty ? host.displayName : newValue
        }
    }
}
