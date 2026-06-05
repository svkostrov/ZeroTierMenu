import SwiftUI

struct SettingsView: View {
    @Bindable var store: NetworkStore

    var body: some View {
        Form {
            Section("Сеть") {
                Text(store.networks.isEmpty ? "Активные сети не найдены" : "\(store.networks.count)")
                    .textSelection(.enabled)
                Text("Приложение автоматически находит все активные ZeroTier-сети на этом Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Сканирование") {
                if store.networks.isEmpty {
                    Text("Подсети пока не определены")
                } else {
                    ForEach(store.networks) { network in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(network.name.isEmpty ? network.networkID : network.name)
                            Text(network.subnet ?? "Подсеть не определена")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Приложение сканирует живые IP во всех активных ZeroTier-подсетях. Имена будут видны только там, где работает reverse DNS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
