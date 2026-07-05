import Foundation
import SafariServices
import WebKit

struct MobileCentralMemberRecord {
    let id: String
    let name: String?
    let ipv4Addresses: [String]
    let lastSeenTime: String?
    let operatingSystem: String?
    let isOnline: Bool
}

@MainActor
final class MobileCentralSession: NSObject {
    private(set) var webView: WKWebView

    private(set) var currentURL: URL?
    private(set) var isLoading = false
    private var pendingFetchContinuation: CheckedContinuation<String, Error>?

    override init() {
        webView = Self.makeWebView()
        super.init()
        configureWebView(webView)
    }

    func loadLogin() {
        guard let url = URL(string: "https://central.zerotier.com/") else { return }
        webView.load(URLRequest(url: url))
    }

    func loadNetwork(_ networkID: String) {
        guard let url = URL(string: "https://central.zerotier.com/network/\(networkID)") else { return }
        webView.load(URLRequest(url: url))
    }

    func fetchMembers(networkID: String) async throws -> [MobileCentralMemberRecord] {
        let script = """
        (() => {
          fetch("https://central.zerotier.com/api/v2/network/\(networkID)/member", {
            method: "GET",
            credentials: "include",
            headers: { "accept": "application/json" }
          })
          .then(async (response) => {
            const text = await response.text();
            window.webkit.messageHandlers.centralFetch.postMessage(JSON.stringify({
              ok: response.ok,
              status: response.status,
              contentType: response.headers.get("content-type") || "",
              text
            }));
          })
          .catch((error) => {
            window.webkit.messageHandlers.centralFetch.postMessage(JSON.stringify({
              ok: false,
              status: 0,
              contentType: "",
              text: String(error)
            }));
          });
          return null;
        })();
        """

        let jsonText = try await runScriptAndWaitForMessage(script)
        guard let data = jsonText.data(using: .utf8) else {
            throw MobileCentralSessionError.invalidResponse
        }

        let response = try JSONDecoder().decode(MobileCentralFetchEnvelope.self, from: data)
        if response.status == 401 || response.status == 403 {
            throw MobileCentralSessionError.unauthorized
        }
        guard response.ok,
              response.contentType.localizedCaseInsensitiveContains("json"),
              let payloadData = response.text.data(using: .utf8) else {
            throw MobileCentralSessionError.httpStatus(response.status)
        }

        return try parseMembers(from: payloadData, networkID: networkID)
    }

    func fetchMembers(networkID: String, apiToken: String) async throws -> [MobileCentralMemberRecord] {
        guard let url = URL(string: "https://api.zerotier.com/api/v1/network/\(networkID)/member") else {
            throw MobileCentralSessionError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("token \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MobileCentralSessionError.invalidResponse
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw MobileCentralSessionError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw MobileCentralSessionError.httpStatus(httpResponse.statusCode)
        }

        return try parseMembers(from: data, networkID: networkID)
    }

    func clearSession() async {
        let dataStore = webView.configuration.websiteDataStore

        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { cookies in
                let group = DispatchGroup()
                for cookie in cookies where cookie.domain.contains("zerotier.com") {
                    group.enter()
                    dataStore.httpCookieStore.delete(cookie) {
                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    continuation.resume()
                }
            }
        }

        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: types) { records in
                continuation.resume(returning: records)
            }
        }

        let matchingRecords = records.filter { $0.displayName.contains("zerotier.com") }
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: types, for: matchingRecords) {
                continuation.resume()
            }
        }

        webView.loadHTMLString("", baseURL: nil)
        currentURL = nil
    }

    func hasCentralCookies() async -> Bool {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.contains(where: { $0.domain.contains("zerotier.com") }))
            }
        }
    }

    func rebuildWebView() {
        pendingFetchContinuation?.resume(throwing: MobileCentralSessionError.requestCancelled)
        pendingFetchContinuation = nil

        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "centralFetch")

        currentURL = nil
        isLoading = false

        let newWebView = Self.makeWebView()
        configureWebView(newWebView)
        webView = newWebView
    }

    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    private func configureWebView(_ webView: WKWebView) {
        webView.configuration.userContentController.add(self, contentWorld: .page, name: "centralFetch")
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    private func runScriptAndWaitForMessage(_ script: String) async throws -> String {
        if pendingFetchContinuation != nil {
            throw MobileCentralSessionError.requestAlreadyInFlight
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingFetchContinuation = continuation
            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    let pending = self.pendingFetchContinuation
                    self.pendingFetchContinuation = nil
                    pending?.resume(throwing: error)
                }
            }
        }
    }

    private func parseMembers(from data: Data, networkID: String) throws -> [MobileCentralMemberRecord] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let items = json as? [[String: Any]] else {
            throw MobileCentralSessionError.invalidResponse
        }

        return items.compactMap { item in
            let config = item["config"] as? [String: Any]
            let memberID = string(item["deviceId"])
                ?? string(item["id"])
                ?? string(item["nodeId"])
                ?? string(config?["id"])
                ?? string(config?["nodeId"])
            let ipv4Addresses = (
                stringArray(item["ipv4Assignments"]) +
                stringArray(item["ipAssignments"]) +
                stringArray(config?["ipAssignments"])
            ).filter { $0.contains(".") }

            guard let memberID = memberID ?? ipv4Addresses.first else { return nil }

            let isOnline = bool(item["online"])
                ?? bool(item["activeBridge"])
                ?? bool(config?["online"])
                ?? recentDateFlag(item["lastOnline"])
                ?? recentDateFlag(item["lastSeen"])
                ?? false

            return MobileCentralMemberRecord(
                id: "\(networkID)|\(memberID)",
                name: string(item["name"]) ?? string(config?["name"]),
                ipv4Addresses: Array(NSOrderedSet(array: ipv4Addresses)) as? [String] ?? ipv4Addresses,
                lastSeenTime: string(item["lastSeenTime"]) ?? string(item["lastSeen"]) ?? string(item["lastOnline"]),
                operatingSystem: string(item["os"]) ?? string(item["platform"]) ?? string(config?["os"]),
                isOnline: isOnline
            )
        }
    }

    private func string(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private func stringArray(_ value: Any?) -> [String] {
        if let values = value as? [String] {
            return values
        }
        if let values = value as? [Any] {
            return values.compactMap { string($0) }
        }
        if let value = string(value) {
            return [value]
        }
        return []
    }

    private func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1", "yes", "online":
                return true
            case "false", "0", "no", "offline":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private func recentDateFlag(_ value: Any?) -> Bool? {
        guard let raw = string(value) else { return nil }
        if let interval = TimeInterval(raw) {
            return Date().timeIntervalSince1970 - interval < 600
        }
        if let date = ISO8601DateFormatter().date(from: raw) {
            return Date().timeIntervalSince(date) < 600
        }
        return nil
    }
}

private struct MobileCentralFetchEnvelope: Decodable {
    let ok: Bool
    let status: Int
    let contentType: String
    let text: String
}

extension MobileCentralSession: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            guard message.name == "centralFetch",
                  let continuation = self.pendingFetchContinuation else { return }
            self.pendingFetchContinuation = nil

            if let text = message.body as? String {
                continuation.resume(returning: text)
            } else {
                continuation.resume(throwing: MobileCentralSessionError.invalidResponse)
            }
        }
    }
}

extension MobileCentralSession: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        currentURL = webView.url
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        currentURL = webView.url
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        currentURL = webView.url
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        currentURL = webView.url
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

enum MobileCentralSessionError: LocalizedError {
    case invalidResponse
    case unauthorized
    case httpStatus(Int)
    case requestAlreadyInFlight
    case requestCancelled

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Central вернул неожиданный ответ."
        case .unauthorized:
            return "Нужно снова войти в ZeroTier Central."
        case .httpStatus(let code):
            return "Central вернул ошибку HTTP \(code)."
        case .requestAlreadyInFlight:
            return "Запрос уже выполняется."
        case .requestCancelled:
            return "Запрос был отменён."
        }
    }
}
