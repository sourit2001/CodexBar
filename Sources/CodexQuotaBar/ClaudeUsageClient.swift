import Foundation

// Reads Claude Code's subscription quota (the same numbers `/usage` shows).
//
// The OAuth credentials live in the macOS Keychain entry that the Claude Code
// CLI maintains ("Claude Code-credentials"), with ~/.claude/.credentials.json
// as a fallback. When the access token is about to expire (or the API answers
// 401) this app refreshes it with the stored refresh token and writes the new
// tokens back to the same place, in the same format Claude Code uses, so the
// CLI keeps working with the rotated tokens.

enum ClaudeUsageError: LocalizedError {
    case credentialsMissing
    case refreshFailed(String)
    case unauthorized
    case rateLimited
    case http(Int)
    case invalidResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .credentialsMissing: return "未找到 Claude Code 登录信息，请用命令行 claude 登录一次"
        case .refreshFailed(let detail): return "Claude 令牌续期失败（\(detail)），运行一次 claude 即可恢复"
        case .unauthorized: return "Claude 令牌无效，请在命令行 claude 中重新登录"
        case .rateLimited: return "Claude 接口请求过于频繁，稍后重试"
        case .http(let code): return "Claude 接口错误 HTTP \(code)"
        case .invalidResponse: return "Claude 接口返回格式异常"
        case .network(let message): return message
        }
    }
}

struct ClaudeUsageWindow {
    let utilization: Double
    let resetsAt: Date?

    var usedPercent: Int { Int(utilization.rounded()) }
    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
}

struct ClaudeUsageSnapshot {
    let fiveHour: ClaudeUsageWindow?
    let sevenDay: ClaudeUsageWindow?
}

final class ClaudeUsageClient {
    private static let keychainService = "Claude Code-credentials"
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenEndpoints = [
        "https://console.anthropic.com/v1/oauth/token",
        "https://platform.claude.com/v1/oauth/token"
    ]
    /// Refresh this long before the recorded expiry.
    private static let refreshMargin: TimeInterval = 5 * 60

    private let queue = DispatchQueue(label: "CodexQuotaBar.ClaudeUsageClient")
    private let session: URLSession
    private var inFlight = false
    private var waiting: [(Result<ClaudeUsageSnapshot, Error>) -> Void] = []

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    func readUsage(completion: @escaping (Result<ClaudeUsageSnapshot, Error>) -> Void) {
        queue.async {
            self.waiting.append(completion)
            guard !self.inFlight else { return }
            self.inFlight = true
            // All work below is synchronous on this serial background queue.
            let result = self.fetch()
            let callbacks = self.waiting
            self.waiting.removeAll()
            self.inFlight = false
            callbacks.forEach { $0(result) }
        }
    }

    // MARK: - Flow

    private func fetch() -> Result<ClaudeUsageSnapshot, Error> {
        guard var credentials = Self.loadCredentials() else {
            AppLog.write("claude credentials missing")
            return .failure(ClaudeUsageError.credentialsMissing)
        }

        var refreshed = false
        if credentials.needsRefresh(margin: Self.refreshMargin) {
            switch refresh(credentials) {
            case .success(let updated):
                credentials = updated
                refreshed = true
            case .failure(let error):
                return .failure(error)
            }
        }

        var result = requestUsage(accessToken: credentials.accessToken)
        if case .failure(let error) = result,
           case .unauthorized? = error as? ClaudeUsageError,
           !refreshed {
            AppLog.write("claude usage 401, refreshing token")
            switch refresh(credentials) {
            case .success(let updated):
                result = requestUsage(accessToken: updated.accessToken)
            case .failure(let error):
                return .failure(error)
            }
        }
        return result
    }

    private func requestUsage(accessToken: String) -> Result<ClaudeUsageSnapshot, Error> {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, status, error) = perform(request)
        if let error {
            AppLog.write("claude usage request failed: \(error.localizedDescription)")
            return .failure(ClaudeUsageError.network(error.localizedDescription))
        }
        guard status == 200, let data else {
            AppLog.write("claude usage http \(status)")
            switch status {
            case 401: return .failure(ClaudeUsageError.unauthorized)
            case 429: return .failure(ClaudeUsageError.rateLimited)
            default: return .failure(ClaudeUsageError.http(status))
            }
        }
        AppLog.write("claude usage raw: \(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
        guard let snapshot = Self.parseUsage(data) else {
            return .failure(ClaudeUsageError.invalidResponse)
        }
        return .success(snapshot)
    }

    // MARK: - Token refresh

    private func refresh(_ stale: Credentials) -> Result<Credentials, Error> {
        // Claude Code may have refreshed the token in the meantime; refresh
        // tokens rotate, so always start from the freshest stored copy.
        let current = Self.loadCredentials() ?? stale
        if current.accessToken != stale.accessToken, !current.needsRefresh(margin: Self.refreshMargin) {
            AppLog.write("claude token already refreshed elsewhere")
            return .success(current)
        }
        guard let refreshToken = current.refreshToken else {
            return .failure(ClaudeUsageError.refreshFailed("没有 refresh token"))
        }

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.oauthClientID
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(ClaudeUsageError.refreshFailed("无法编码请求"))
        }

        var lastDetail = "未知错误"
        for endpoint in Self.tokenEndpoints {
            var request = URLRequest(url: URL(string: endpoint)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = bodyData

            let (data, status, error) = perform(request)
            if let error {
                lastDetail = error.localizedDescription
                AppLog.write("claude refresh \(endpoint) failed: \(lastDetail)")
                continue
            }
            guard status == 200,
                  let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
                lastDetail = "HTTP \(status)"
                let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                AppLog.write("claude refresh \(endpoint) http \(status): \(bodyText.prefix(300))")
                // 400/401 means the refresh token itself was rejected; another
                // endpoint will not change that.
                if status == 400 || status == 401 { break }
                continue
            }

            let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue ?? 8 * 3600
            let updated = current.updated(
                accessToken: accessToken,
                refreshToken: (object["refresh_token"] as? String) ?? refreshToken,
                expiresAt: Date().addingTimeInterval(expiresIn)
            )
            if Self.save(updated) {
                AppLog.write("claude token refreshed via \(endpoint), expires in \(Int(expiresIn))s")
            } else {
                AppLog.write("claude token refreshed but saving failed")
            }
            return .success(updated)
        }
        return .failure(ClaudeUsageError.refreshFailed(lastDetail))
    }

    // MARK: - HTTP

    private func perform(_ request: URLRequest) -> (Data?, Int, Error?) {
        let semaphore = DispatchSemaphore(value: 0)
        var output: (Data?, Int, Error?) = (nil, 0, nil)
        session.dataTask(with: request) { data, response, error in
            output = (data, (response as? HTTPURLResponse)?.statusCode ?? 0, error)
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return output
    }

    // MARK: - Parsing

    private static func parseUsage(_ data: Data) -> ClaudeUsageSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return ClaudeUsageSnapshot(
            fiveHour: window(object["five_hour"]),
            sevenDay: window(object["seven_day"])
        )
    }

    private static func window(_ value: Any?) -> ClaudeUsageWindow? {
        guard let dictionary = value as? [String: Any],
              let utilization = (dictionary["utilization"] as? NSNumber)?.doubleValue else {
            return nil
        }
        let resetsAt = (dictionary["resets_at"] as? String).flatMap(parseDate)
        return ClaudeUsageWindow(utilization: utilization, resetsAt: resetsAt)
    }

    /// Accepts ISO 8601 with or without fractional seconds (any precision).
    private static func parseDate(_ string: String) -> Date? {
        var trimmed = string
        if let dot = trimmed.firstIndex(of: ".") {
            var end = trimmed.index(after: dot)
            while end < trimmed.endIndex, trimmed[end].isNumber {
                end = trimmed.index(after: end)
            }
            trimmed.removeSubrange(dot..<end)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    // MARK: - Credentials

    private enum Source {
        case keychain(account: String)
        case file(URL)
    }

    private struct Credentials {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        /// The whole stored document, kept so unrelated fields survive a write.
        let document: [String: Any]
        let source: Source

        func needsRefresh(margin: TimeInterval) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < margin
        }

        func updated(accessToken: String, refreshToken: String, expiresAt: Date) -> Credentials {
            var document = self.document
            var oauth = document["claudeAiOauth"] as? [String: Any] ?? [:]
            oauth["accessToken"] = accessToken
            oauth["refreshToken"] = refreshToken
            oauth["expiresAt"] = Int64(expiresAt.timeIntervalSince1970 * 1000)
            document["claudeAiOauth"] = oauth
            return Credentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt,
                document: document,
                source: source
            )
        }
    }

    private static var credentialsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
    }

    private static func loadCredentials() -> Credentials? {
        if let item = readKeychain() {
            if let credentials = decodeCredentials(item.data, source: .keychain(account: item.account)) {
                return credentials
            }
            AppLog.write("claude keychain item has no claudeAiOauth.accessToken")
        }
        let fileURL = credentialsFileURL
        if let data = try? Data(contentsOf: fileURL) {
            if let credentials = decodeCredentials(data, source: .file(fileURL)) {
                AppLog.write("claude credentials from \(fileURL.path)")
                return credentials
            }
            AppLog.write("claude credentials file has no claudeAiOauth.accessToken")
        } else {
            AppLog.write("claude credentials file not found")
        }
        return nil
    }

    private static func decodeCredentials(_ data: Data, source: Source) -> Credentials? {
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = document["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return nil
        }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map { number -> Date in
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        return Credentials(
            accessToken: token,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: expiresAt,
            document: document,
            source: source
        )
    }

    private static func save(_ credentials: Credentials) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: credentials.document) else {
            return false
        }
        switch credentials.source {
        case .keychain(let account):
            // Same call shape Claude Code itself uses, so the item stays
            // readable by the CLI.
            let hex = data.map { String(format: "%02x", $0) }.joined()
            let result = runSecurity(["add-generic-password", "-U", "-a", account, "-s", keychainService, "-X", hex])
            if result.status != 0 {
                AppLog.write("claude keychain write failed: \(result.error)")
            }
            return result.status == 0
        case .file(let url):
            do {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return true
            } catch {
                AppLog.write("claude credentials file write failed: \(error.localizedDescription)")
                return false
            }
        }
    }

    // MARK: - Keychain via /usr/bin/security

    /// Uses /usr/bin/security so the first run shows the standard Keychain
    /// prompt; choose "始终允许" (Always Allow) to stop it reappearing.
    private static func readKeychain() -> (data: Data, account: String)? {
        let secret = runSecurity(["find-generic-password", "-s", keychainService, "-w"])
        guard secret.status == 0 else {
            AppLog.write("claude keychain: security exit \(secret.status) \(secret.error)")
            return nil
        }
        let text = secret.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let attributes = runSecurity(["find-generic-password", "-s", keychainService])
        let account = parseAccount(attributes.output + attributes.error) ?? NSUserName()
        return (Data(text.utf8), account)
    }

    /// Extracts `"acct"<blob>="name"` from `security find-generic-password` output.
    private static func parseAccount(_ text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("\"acct\"<blob>=\"") {
            guard let start = line.range(of: "<blob>=\"")?.upperBound,
                  let end = line.lastIndex(of: "\""), end > start else { continue }
            return String(line[start..<end])
        }
        return nil
    }

    private static func runSecurity(_ arguments: [String]) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        let errData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
