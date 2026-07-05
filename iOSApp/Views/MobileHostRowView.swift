import SwiftUI

struct MobileHostRowView: View {
    let host: MobileNetworkHost
    let initialAlias: String
    let copyAction: (String) -> Void
    let saveAliasAction: (String) -> Void

    @State private var aliasDraft: String

    init(
        host: MobileNetworkHost,
        initialAlias: String,
        copyAction: @escaping (String) -> Void,
        saveAliasAction: @escaping (String) -> Void
    ) {
        self.host = host
        self.initialAlias = initialAlias
        self.copyAction = copyAction
        self.saveAliasAction = saveAliasAction
        _aliasDraft = State(initialValue: initialAlias.isEmpty ? host.name : initialAlias)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(host.isOnline ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 10, height: 10)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Имя хоста", text: $aliasDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            saveAliasAction(aliasDraft)
                        }

                    if let address = host.ipv4Addresses.first {
                        Button {
                            copyAction(address)
                        } label: {
                            Label(address, systemImage: "doc.on.doc")
                                .font(.system(.footnote, design: .monospaced))
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Spacer(minLength: 0)
            }

            if let operatingSystem = host.operatingSystem, !operatingSystem.isEmpty {
                Text("OS: \(operatingSystem)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let lastSeenText = host.lastSeenText {
                Text("Последняя активность: \(lastSeenText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        .onChange(of: initialAlias) { _, newValue in
            aliasDraft = newValue.isEmpty ? host.name : newValue
        }
    }
}
