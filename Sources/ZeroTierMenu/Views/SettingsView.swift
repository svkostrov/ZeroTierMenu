import SwiftUI

struct SettingsView: View {
    @Bindable var store: NetworkStore

    var body: some View {
        Form {
            Section("Central") {
                Text("Приложение получает участников сети из ZeroTier Central через встроенный WKWebView, а доступность хостов определяет ping.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Сеть") {
                Text(store.networks.isEmpty ? "Активные сети не найдены" : "\(store.networks.count)")
                    .textSelection(.enabled)
                Text("Приложение автоматически находит все активные ZeroTier-сети на этом Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Обновление") {
                Text("Откройте авторизацию Central, войдите подходящим способом и затем обновите список хостов.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
