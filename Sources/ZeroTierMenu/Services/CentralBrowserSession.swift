import Foundation
import WebKit

struct CentralMemberRecord {
    let id: String
    let name: String?
    let ipv4Addresses: [String]
    let lastSeenTime: String?
    let operatingSystem: String?
}

@MainActor
final class CentralBrowserSession: NSObject {
    let webView: WKWebView

    private(set) var currentURL: URL?
    private(set) var pageTitle = ""
    private(set) var isLoading = false
    private var pendingFetchContinuation: CheckedContinuation<String, Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, contentWorld: .page, name: "centralFetch")
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func loadLogin(networkID: String?) {
        let urlString: String
        if let networkID, !networkID.isEmpty {
            urlString = "https://central.zerotier.com/network/\(networkID)"
        } else {
            urlString = "https://central.zerotier.com/"
        }

        guard let url = URL(string: urlString) else { return }
        webView.load(URLRequest(url: url))
    }

    func reloadNetwork(networkID: String) {
        loadLogin(networkID: networkID)
    }

    func fetchMembers(networkID: String) async throws -> [CentralMemberRecord] {
        do {
            let apiMembers = try await fetchMembersViaAPI(networkID: networkID)
            if !apiMembers.isEmpty {
                return apiMembers
            }
        } catch {
            let domMembers = try await fetchMembersFromVisiblePage(networkID: networkID)
            if !domMembers.isEmpty {
                return domMembers
            }

            throw error
        }

        let domMembers = try await fetchMembersFromVisiblePage(networkID: networkID)
        if !domMembers.isEmpty {
            return domMembers
        }

        throw CentralBrowserSessionError.noMembersFoundOnPage
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

        let recordTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: recordTypes) { records in
                continuation.resume(returning: records)
            }
        }

        let matchingRecords = records.filter { $0.displayName.contains("zerotier.com") }
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: recordTypes, for: matchingRecords) {
                continuation.resume()
            }
        }

        webView.loadHTMLString("", baseURL: nil)
        currentURL = nil
        pageTitle = ""
    }

    func hasCentralCookies() async -> Bool {
        let dataStore = webView.configuration.websiteDataStore
        return await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.contains(where: { $0.domain.contains("zerotier.com") }))
            }
        }
    }

    private func fetchMembersViaAPI(networkID: String) async throws -> [CentralMemberRecord] {
        let script = """
        (() => {
          fetch("https://central.zerotier.com/api/v2/network/\(networkID)/member", {
            method: "GET",
            credentials: "include",
            headers: {
              "accept": "application/json"
            }
          })
          .then(async (response) => {
            const text = await response.text();
            const payload = JSON.stringify({
              kind: "api",
              ok: response.ok,
              status: response.status,
              url: response.url,
              contentType: response.headers.get("content-type") || "",
              text
            });
            window.webkit.messageHandlers.centralFetch.postMessage(payload);
          })
          .catch((error) => {
            const payload = JSON.stringify({
              kind: "api",
              ok: false,
              status: 0,
              url: "",
              contentType: "",
              text: String(error)
            });
            window.webkit.messageHandlers.centralFetch.postMessage(payload);
          });
          return null;
        })();
        """

        let jsonText = try await runScriptAndWaitForMessage(script)
        guard let data = jsonText.data(using: .utf8) else {
            throw CentralBrowserSessionError.invalidResponse
        }

        let response = try JSONDecoder().decode(CentralFetchEnvelope.self, from: data)
        if response.status == 401 || response.status == 403 {
            throw CentralBrowserSessionError.unauthorized
        }
        guard response.ok else {
            throw CentralBrowserSessionError.httpStatus(response.status)
        }
        guard response.contentType.localizedCaseInsensitiveContains("json"),
              let payloadData = response.text.data(using: .utf8) else {
            throw CentralBrowserSessionError.unauthorized
        }

        return try parseMembers(from: payloadData, networkID: networkID)
    }

    private func fetchMembersFromVisiblePage(networkID: String) async throws -> [CentralMemberRecord] {
        let script = """
        (() => {
          const ipv4Regex = /\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b/;
          const headerCells = Array.from(document.querySelectorAll("thead th")).map((cell) => (cell.innerText || cell.textContent || "").trim());
          const rows = Array.from(document.querySelectorAll("tr"));
          const members = rows.map((row) => {
            const cells = Array.from(row.querySelectorAll("td,th"))
              .map((cell) => (cell.innerText || cell.textContent || "").trim())
              .filter(Boolean);
            if (cells.length < 4) {
              return null;
            }

            const ip = cells.find((value) => ipv4Regex.test(value));
            if (!ip) {
              return null;
            }

            const deviceId = cells[0];
            const name = cells[1];
            const byHeader = Object.fromEntries(cells.map((value, index) => [headerCells[index] || String(index), value]));
            const lastActive = byHeader["Last Active"] || byHeader["Last Seen"] || byHeader["Updated"];
            const operatingSystem = byHeader["OS"] || byHeader["Platform"] || byHeader["Operating System"];
            return {
              deviceId,
              name,
              ipv4Assignments: [ip.match(ipv4Regex)[0]],
              lastSeenTime: lastActive || null,
              os: operatingSystem || null
            };
          }).filter(Boolean);

          const payload = JSON.stringify({
            kind: "dom",
            ok: true,
            status: members.length > 0 ? 200 : 404,
            url: window.location.href,
            contentType: "application/json",
            text: JSON.stringify(members)
          });
          window.webkit.messageHandlers.centralFetch.postMessage(payload);
          return null;
        })();
        """

        let jsonText = try await runScriptAndWaitForMessage(script)
        guard let data = jsonText.data(using: .utf8) else {
            throw CentralBrowserSessionError.invalidResponse
        }

        let response = try JSONDecoder().decode(CentralFetchEnvelope.self, from: data)
        guard response.ok,
              let payloadData = response.text.data(using: .utf8) else {
            throw CentralBrowserSessionError.noMembersFoundOnPage
        }

        return try parseMembers(from: payloadData, networkID: networkID)
    }

    private func runScriptAndWaitForMessage(_ script: String) async throws -> String {
        if pendingFetchContinuation != nil {
            throw CentralBrowserSessionError.requestAlreadyInFlight
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

    private func parseMembers(from data: Data, networkID: String) throws -> [CentralMemberRecord] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let items = json as? [[String: Any]] else {
            throw CentralBrowserSessionError.invalidResponse
        }

        return items.compactMap { item in
            let config = item["config"] as? [String: Any]
            let memberID = string(item["deviceId"])
                ?? string(item["id"])
                ?? string(item["nodeId"])
                ?? string(item["nodeID"])
                ?? string(config?["id"])
                ?? string(config?["nodeId"])

            let memberName = string(item["name"])
                ?? string(item["displayName"])
                ?? string(config?["name"])
                ?? string(config?["displayName"])

            let ipv4Addresses = (
                stringArray(item["ipv4Assignments"]) +
                stringArray(item["ipAssignments"]) +
                stringArray(config?["ipAssignments"])
            )
            .filter { $0.contains(".") }
            let lastSeenTime = string(item["lastSeenTime"])
                ?? string(item["lastActive"])
                ?? string(config?["lastSeenTime"])
            let operatingSystem = string(item["os"])
                ?? string(item["platform"])
                ?? string(config?["os"])

            guard let memberID = memberID ?? ipv4Addresses.first else {
                return nil
            }

            return CentralMemberRecord(
                id: "\(networkID)|\(memberID)",
                name: memberName,
                ipv4Addresses: Array(NSOrderedSet(array: ipv4Addresses)) as? [String] ?? ipv4Addresses,
                lastSeenTime: lastSeenTime,
                operatingSystem: operatingSystem
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
}

private struct CentralFetchEnvelope: Decodable {
    let ok: Bool
    let status: Int
    let url: String
    let contentType: String
    let text: String
}

extension CentralBrowserSession: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            guard message.name == "centralFetch" else { return }
            guard let continuation = self.pendingFetchContinuation else { return }
            self.pendingFetchContinuation = nil

            if let text = message.body as? String {
                continuation.resume(returning: text)
                return
            }

            if let dict = message.body as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: dict),
               let text = String(data: data, encoding: .utf8) {
                continuation.resume(returning: text)
                return
            }

            if let array = message.body as? [Any],
               let data = try? JSONSerialization.data(withJSONObject: array),
               let text = String(data: data, encoding: .utf8) {
                continuation.resume(returning: text)
                return
            }

            continuation.resume(throwing: CentralBrowserSessionError.unsupportedJavaScriptResult)
        }
    }
}

extension CentralBrowserSession: WKNavigationDelegate {
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
        pageTitle = webView.title ?? ""
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        currentURL = webView.url
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        currentURL = webView.url
    }
}

extension CentralBrowserSession: WKUIDelegate {
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

enum CentralBrowserSessionError: LocalizedError {
    case invalidResponse
    case unauthorized
    case httpStatus(Int)
    case unsupportedJavaScriptResult
    case requestAlreadyInFlight
    case noMembersFoundOnPage

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Central вернул неожиданный ответ."
        case .unauthorized:
            return "Сессия Central недействительна. Нужно войти снова."
        case .httpStatus(let code):
            return "Central вернул ошибку HTTP \(code)."
        case .unsupportedJavaScriptResult:
            return "WKWebView вернул неожиданный формат результата JavaScript."
        case .requestAlreadyInFlight:
            return "Запрос к Central уже выполняется."
        case .noMembersFoundOnPage:
            return "Не удалось прочитать members со страницы Central."
        }
    }
}
