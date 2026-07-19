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
    var onNavigationFinished: ((URL?) -> Void)?

    private var pendingFetchContinuation: CheckedContinuation<String, Error>?
    private var currentFetchRequestID: UUID?
    private var navigationWaiters: [NavigationWaiter] = []

    var isOnCentralPage: Bool {
        guard let host = webView.url?.host else { return false }
        return host.contains("zerotier.com")
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, contentWorld: .page, name: "centralFetch")
        let interceptor = WKUserScript(
            source: Self.authHeaderInterceptorScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(interceptor)
        let rememberMe = WKUserScript(
            source: Self.rememberMeScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(rememberMe)
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    private static let authHeaderInterceptorScript = """
    (() => {
      if (window.__ztFetchHooked) { return; }
      window.__ztFetchHooked = true;
      window.__ztAuthHeader = window.__ztAuthHeader || null;

      const remember = (value) => {
        if (value) { window.__ztAuthHeader = value; }
      };

      const readHeaders = (headers) => {
        try {
          if (!headers) { return null; }
          if (typeof headers.get === "function") { return headers.get("authorization"); }
          if (Array.isArray(headers)) {
            const found = headers.find((pair) => String(pair[0]).toLowerCase() === "authorization");
            return found ? found[1] : null;
          }
          for (const key of Object.keys(headers)) {
            if (key.toLowerCase() === "authorization") { return headers[key]; }
          }
        } catch (error) {}
        return null;
      };

      const originalFetch = window.fetch;
      window.fetch = function(input, init) {
        try {
          remember(readHeaders(init && init.headers));
          if (input && typeof input === "object" && input.headers) {
            remember(readHeaders(input.headers));
          }
        } catch (error) {}
        return originalFetch.apply(this, arguments);
      };

      const originalSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
        if (String(name).toLowerCase() === "authorization") { remember(value); }
        return originalSetRequestHeader.apply(this, arguments);
      };
    })();
    """

    /// На странице логина accounts.zerotier.com автоматически ставим галку "Remember me",
    /// чтобы SSO-сессия keycloak жила дольше и авто-переавторизация работала без пароля.
    private static let rememberMeScript = """
    (() => {
      if (!window.location.host.includes("accounts.zerotier.com")) { return; }
      const tick = () => {
        const checkbox = document.querySelector('input#rememberMe, input[name="rememberMe"]');
        if (checkbox && !checkbox.checked) { checkbox.click(); }
      };
      tick();
      const timer = setInterval(tick, 500);
      setTimeout(() => clearInterval(timer), 15000);
    })();
    """

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

    func loadAndWaitForPage(networkID: String?, timeoutSeconds: Double = 20) async {
        loadLogin(networkID: networkID)
        await waitForNavigationEnd(timeoutSeconds: timeoutSeconds)
    }

    private func waitForNavigationEnd(timeoutSeconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = NavigationWaiter(continuation)
            navigationWaiters.append(waiter)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                waiter.resume()
            }
        }
    }

    private func finishNavigationWaiters() {
        let waiters = navigationWaiters
        navigationWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func fetchMembers(networkID: String) async throws -> [CentralMemberRecord] {
        var token = await validAuthToken()
        if token == nil {
            await loadAndWaitForPage(networkID: networkID)
            token = await waitForAuthToken()
        }

        guard let token else {
            if let domMembers = try? await fetchMembersFromVisiblePage(networkID: networkID),
               !domMembers.isEmpty {
                return domMembers
            }
            throw CentralBrowserSessionError.unauthorized
        }

        do {
            return try await fetchMembersViaAPI(networkID: networkID, token: token)
        } catch CentralBrowserSessionError.unauthorized {
            await loadAndWaitForPage(networkID: networkID)
            guard let freshToken = await waitForAuthToken() else {
                throw CentralBrowserSessionError.unauthorized
            }
            return try await fetchMembersViaAPI(networkID: networkID, token: freshToken)
        } catch {
            let domMembers = try await fetchMembersFromVisiblePage(networkID: networkID)
            if !domMembers.isEmpty {
                return domMembers
            }
            throw error
        }
    }

    /// Токен нового Central UI: SPA кладёт JWT в localStorage.currentUser.authToken
    /// и обновляет его по сессионной куке при загрузке страницы.
    private func validAuthToken() async -> String? {
        let script = """
        (() => {
          try {
            const captured = window.__ztAuthHeader || null;
            const raw = localStorage.getItem("currentUser");
            const stored = raw ? (JSON.parse(raw).authToken || null) : null;
            const isFresh = (token) => {
              try {
                const payload = JSON.parse(atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
                return !payload.exp || payload.exp * 1000 > Date.now() + 30000;
              } catch (error) { return false; }
            };
            if (stored && isFresh(stored)) { return stored; }
            if (captured && isFresh(captured)) { return captured; }
            return "";
          } catch (error) { return ""; }
        })();
        """

        let result: String? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }

        guard let result, !result.isEmpty else { return nil }
        return result
    }

    private func waitForAuthToken(timeoutSeconds: Double = 12) async -> String? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let token = await validAuthToken() {
                return token
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    // MARK: - Автоматическая переавторизация через Google

    /// Пробует восстановить сессию без участия пользователя: открывает Central,
    /// на странице логина кликает "Sign in with Google", на accounts.google.com
    /// выбирает аккаунт. Работает, пока жива Google-сессия в cookie-хранилище WKWebView.
    func attemptAutoLogin(networkID: String?, timeoutSeconds: Double = 90) async -> Bool {
        logAutoLogin("start")
        await loadAndWaitForPage(networkID: networkID)
        if await validAuthToken() != nil {
            logAutoLogin("token already valid")
            return true
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var idleSteps = 0
        var spaReloads = 0

        while Date() < deadline {
            if isOnCentralPage, await validAuthToken() != nil {
                logAutoLogin("success at \(webView.url?.absoluteString ?? "-")")
                return true
            }

            // Застряли на central.zerotier.com без токена — например, на OAuth
            // callback (/api/v2/user/login/keycloak/callback), где SPA не запускается.
            // Перезагружаем SPA, чтобы он выпустил свежий JWT по сессионной куке.
            let path = webView.url?.path ?? ""
            if isOnCentralPage, path.hasPrefix("/api/") || idleSteps >= 4 {
                guard spaReloads < 3 else {
                    logAutoLogin("giving up: SPA reloads exhausted at \(path)")
                    return false
                }
                spaReloads += 1
                idleSteps = 0
                logAutoLogin("reload SPA #\(spaReloads) from \(path)")
                await loadAndWaitForPage(networkID: networkID)
                if await waitForAuthToken(timeoutSeconds: 10) != nil {
                    logAutoLogin("success after SPA reload")
                    return true
                }
                continue
            }

            let action = await performAutoLoginStep()
            logAutoLogin("step=\(action) at \(webView.url?.host ?? "-")\(path)")
            if action == "none" || action == "error" || action.hasSuffix("-wait") {
                idleSteps += 1
                // Долго стоим на чужой странице без прогресса —
                // видимо, нужен пароль, без пользователя не продвинемся.
                if idleSteps >= 10 && !isOnCentralPage {
                    logAutoLogin("giving up: stuck at \(webView.url?.absoluteString ?? "-")")
                    return false
                }
                try? await Task.sleep(for: .seconds(1))
            } else {
                idleSteps = 0
                await waitForNavigationEnd(timeoutSeconds: 15)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        let ok = await validAuthToken() != nil
        logAutoLogin(ok ? "success at deadline" : "failed at deadline, url=\(webView.url?.absoluteString ?? "-")")
        return ok
    }

    private func logAutoLogin(_ message: String) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZeroTierMenu", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("autologin.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(timestamp) \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// Делает один шаг авто-логина и возвращает, что удалось сделать.
    private func performAutoLoginStep() async -> String {
        let script = """
        (() => {
          try {
            const host = window.location.host || "";
            const visible = (el) => {
              if (!el) { return false; }
              const rect = el.getBoundingClientRect();
              return rect.width > 0 && rect.height > 0;
            };

            if (host.includes("accounts.google.com") || host.includes("google.com")) {
              const preferred = document.querySelector('[data-identifier="\(Self.preferredGoogleAccount)"]');
              if (preferred && visible(preferred)) { preferred.click(); return "google-account"; }
              const anyAccount = document.querySelector("[data-identifier]");
              if (anyAccount && visible(anyAccount)) { anyAccount.click(); return "google-account"; }
              const approve = document.querySelector("#submit_approve_access button, #submit_approve_access");
              if (approve && visible(approve)) { approve.click(); return "google-approve"; }
              const cont = Array.from(document.querySelectorAll("button"))
                .find((el) => /continue|продолжить|далее|next/i.test(el.innerText || "") && visible(el));
              if (cont) { cont.click(); return "google-continue"; }
              return "google-wait";
            }

            const nodes = Array.from(document.querySelectorAll('button, a, [role="button"], input[type="submit"]'));

            if (host.includes("central.zerotier.com")) {
              // SPA показывает экран логина с кнопкой "Log In", ведущей на keycloak.
              const loginButton = nodes.find((el) => {
                const text = (el.innerText || el.value || "").trim();
                return /^(log ?in|sign ?in|войти)/i.test(text) && visible(el);
              });
              if (loginButton) { loginButton.click(); return "zt-login"; }
            }
            const googleButton = nodes.find((el) => {
              const haystack = [
                el.innerText, el.value, el.title,
                el.getAttribute("aria-label"), el.className, el.id,
                el.getAttribute("href"), el.getAttribute("data-provider")
              ].filter(Boolean).join(" ");
              return /google/i.test(haystack) && visible(el);
            });
            if (googleButton) { googleButton.click(); return "zt-google"; }

            return "none";
          } catch (error) {
            return "error";
          }
        })();
        """

        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: (value as? String) ?? "error")
            }
        }
    }

    private static let preferredGoogleAccount = "zzzrokotzzz@gmail.com"

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

    func collectDiagnostics(networkID: String) async -> String {
        let script = """
        (async () => {
          const report = {};
          report.location = window.location.href;
          report.resources = performance.getEntriesByType("resource")
            .map((entry) => entry.name)
            .filter((url) => url.includes("api") || url.includes("member") || url.includes("network"))
            .slice(-50);

          const candidates = [
            "https://central.zerotier.com/api/v2/network/\(networkID)/member",
            "https://central.zerotier.com/api/network/\(networkID)/member",
            "https://central.zerotier.com/api/v1/network/\(networkID)/member",
            "https://api.zerotier.com/api/v2/network/\(networkID)/member",
            "https://api.zerotier.com/api/v1/network/\(networkID)/member"
          ];

          report.cookie = document.cookie;
          report.localStorageKeys = Object.keys(localStorage);
          report.sessionStorageKeys = Object.keys(sessionStorage);
          report.storageSamples = {};
          for (const key of report.localStorageKeys) {
            const lower = key.toLowerCase();
            if (lower.includes("token") || lower.includes("auth") || lower.includes("oidc") || lower.includes("user") || lower.includes("session")) {
              report.storageSamples["ls:" + key] = String(localStorage.getItem(key)).slice(0, 300);
            }
          }
          for (const key of report.sessionStorageKeys) {
            const lower = key.toLowerCase();
            if (lower.includes("token") || lower.includes("auth") || lower.includes("oidc") || lower.includes("user") || lower.includes("session")) {
              report.storageSamples["ss:" + key] = String(sessionStorage.getItem(key)).slice(0, 300);
            }
          }
          report.capturedAuthHeader = window.__ztAuthHeader || null;

          report.probes = [];
          for (const url of candidates) {
            try {
              const response = await fetch(url, {
                credentials: "include",
                headers: { accept: "application/json" }
              });
              const text = await response.text();
              report.probes.push({
                url,
                status: response.status,
                contentType: response.headers.get("content-type") || "",
                body: text.slice(0, 400)
              });
            } catch (error) {
              report.probes.push({ url, error: String(error) });
            }
          }

          const payload = JSON.stringify({
            kind: "diag",
            ok: true,
            status: 200,
            url: window.location.href,
            contentType: "application/json",
            text: JSON.stringify(report)
          });
          window.webkit.messageHandlers.centralFetch.postMessage(payload);
        })();
        0;
        """

        do {
            let jsonText = try await runScriptAndWaitForMessage(script, timeoutSeconds: 30)
            guard let data = jsonText.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(CentralFetchEnvelope.self, from: data) else {
                return jsonText
            }
            return envelope.text
        } catch {
            return "diagnostics failed: \(error.localizedDescription)"
        }
    }

    private func fetchMembersViaAPI(networkID: String, token: String) async throws -> [CentralMemberRecord] {
        let script = """
        (() => {
          fetch("https://central.zerotier.com/api/v2/network/\(networkID)/member", {
            method: "GET",
            credentials: "include",
            headers: {
              "accept": "application/json",
              "authorization": "\(token)"
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

    private func runScriptAndWaitForMessage(_ script: String, timeoutSeconds: Double = 15) async throws -> String {
        if pendingFetchContinuation != nil {
            throw CentralBrowserSessionError.requestAlreadyInFlight
        }

        let requestID = UUID()
        currentFetchRequestID = requestID

        return try await withCheckedThrowingContinuation { continuation in
            pendingFetchContinuation = continuation
            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    let pending = self.pendingFetchContinuation
                    self.pendingFetchContinuation = nil
                    self.currentFetchRequestID = nil
                    pending?.resume(throwing: error)
                }
            }

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard let self,
                      self.currentFetchRequestID == requestID,
                      let pending = self.pendingFetchContinuation else { return }
                self.pendingFetchContinuation = nil
                self.currentFetchRequestID = nil
                pending.resume(throwing: CentralBrowserSessionError.timedOut)
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
        finishNavigationWaiters()
        onNavigationFinished?(webView.url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        currentURL = webView.url
        finishNavigationWaiters()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        currentURL = webView.url
        finishNavigationWaiters()
    }
}

@MainActor
private final class NavigationWaiter {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
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
    case timedOut

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
        case .timedOut:
            return "Central не ответил вовремя."
        }
    }
}
