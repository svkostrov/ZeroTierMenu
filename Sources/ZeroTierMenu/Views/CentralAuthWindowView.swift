import SwiftUI
import WebKit

struct CentralAuthWindowView: View {
    @Bindable var store: NetworkStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ZeroTier Central")
                        .font(.headline)

                    Text("Войдите тем способом, который привязан к вашей сети.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Закрыть") {
                    store.closeCentralAuthWindow()
                }
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                Button("Открыть сеть") {
                    store.loadCentralLoginPage()
                }
                .controlSize(.small)

                Button("Обновить") {
                    store.reloadCentralLoginPage()
                }
                .controlSize(.small)

                Button("Сбросить сессию") {
                    Task {
                        await store.clearCentralSession()
                    }
                }
                .controlSize(.small)

                Spacer()

                if let urlText = store.centralBrowserURLText, !urlText.isEmpty {
                    Text(urlText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Text(store.centralSessionState.title)
                .font(.caption)
                .foregroundStyle(store.centralSessionState == .needsLogin ? .orange : .secondary)

            CentralWebViewContainer(webView: store.centralSession.webView)
                .frame(minWidth: 900, minHeight: 700)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Text("После входа закройте окно и нажмите «Обновить Central» в режиме v2.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .onAppear {
            store.loadCentralLoginPage()
        }
    }
}

private struct CentralWebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
    }
}
