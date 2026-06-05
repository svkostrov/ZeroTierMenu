import SwiftUI

struct SettingsView: View {
    @Bindable var store: NetworkStore

    var body: some View {
        Form {
            Section("Сеть") {
                TextField("Network ID", text: $store.networkID)
                    .textFieldStyle(.roundedBorder)
                Text("Сейчас предзаполнена ваша сеть из ссылки.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Сканирование") {
                Text(store.subnetCIDR ?? "Подсеть пока не определена")
                    .textSelection(.enabled)
                Text("Приложение сканирует живые IP в локальной ZeroTier-подсети. Имена будут видны только там, где работает reverse DNS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
