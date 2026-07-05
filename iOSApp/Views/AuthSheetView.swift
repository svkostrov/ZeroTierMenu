import SwiftUI
import UIKit
import WebKit

struct AuthSheetView: View {
    @Bindable var store: ZeroTierCompanionStore
    @Environment(\.dismiss) private var dismiss
    @State private var tokenDraft = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Для Google-входа встроенный браузер iOS не подходит. Используйте API token ZeroTier Central.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("API token", text: $tokenDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                    HStack {
                        Button("Сохранить token") {
                            store.saveAPIToken(tokenDraft)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Открыть Central в Safari") {
                            guard let url = URL(string: "https://central.zerotier.com/account") else { return }
                            UIApplication.shared.open(url)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(16)

                HStack {
                    Text(store.centralSessionState.title)
                        .font(.caption)
                        .foregroundStyle(store.centralSessionState == .needsLogin ? .orange : .secondary)

                    Spacer()

                    if let url = store.centralSession.currentURL?.absoluteString, !url.isEmpty {
                        Text(url)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                IOSCentralWebView(webView: store.centralSession.webView)
                    .id(ObjectIdentifier(store.centralSession.webView))
            }
            .navigationTitle("ZeroTier Central")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Открыть") {
                        if store.selectedNetworkID.isEmpty {
                            store.centralSession.loadLogin()
                        } else {
                            store.centralSession.loadNetwork(store.selectedNetworkID)
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(false)
        .onAppear {
            tokenDraft = store.apiToken
        }
    }
}

private struct IOSCentralWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
    }
}
