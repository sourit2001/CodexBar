import AppKit
import Foundation

enum CodexAppServerError: LocalizedError {
    case codexExecutableMissing
    case processNotRunning
    case rpcError(String)
    case timeout
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .codexExecutableMissing:
            return "找不到 Codex 或 ChatGPT.app"
        case .processNotRunning:
            return "Codex app-server 未运行"
        case .rpcError(let message):
            return message
        case .timeout:
            return "Codex app-server 响应超时"
        case .invalidResponse:
            return "Codex app-server 返回格式异常"
        }
    }
}

final class CodexAppServerClient {
    /// Finds a Codex executable: bundled in ChatGPT.app / Codex.app (wherever
    /// the app is installed), then the standalone `codex` CLI.
    static func locateExecutable() -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        var appPaths = [
            "/Applications/ChatGPT.app",
            "/Applications/Codex.app",
            "\(home)/Applications/ChatGPT.app",
            "\(home)/Applications/Codex.app"
        ]
        for bundleID in ["com.openai.chat", "com.openai.codex"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                if !appPaths.contains(url.path) { appPaths.append(url.path) }
            }
        }
        var candidates = appPaths.map { "\($0)/Contents/Resources/codex" }
        // Newer ChatGPT builds ship codex inside "Codex Framework.framework"
        // under a versioned folder, so search the bundle for it.
        for appPath in appPaths where fileManager.fileExists(atPath: appPath) {
            candidates += bundledExecutables(inApp: appPath)
        }
        candidates += [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.bun/bin/codex"
        ]
        let found = candidates.first(where: fileManager.isExecutableFile)
        AppLog.write("codex executable: \(found ?? "not found; tried \(candidates)")")
        return found
    }
    private let queue = DispatchQueue(label: "CodexQuotaBar.CodexAppServerClient")
    private var process: Process?
    private var stdout = Pipe()
    private var stdin = Pipe()
    private var stderr = Pipe()
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: (Result<Data, Error>) -> Void] = [:]
    private var initialized = false
    private var initializing = false
    private var initializationCallbacks: [(Result<Void, Error>) -> Void] = []
    private var lastStderr = ""

    func start() {
        queue.async {
            _ = self.startLocked()
        }
    }

    func stop() {
        queue.async {
            self.stdout.fileHandleForReading.readabilityHandler = nil
            self.stderr.fileHandleForReading.readabilityHandler = nil
            self.process?.terminate()
            self.process = nil
            self.pending.removeAll()
        }
    }

    func readRateLimits(completion: @escaping (Result<RateLimitSnapshot, Error>) -> Void) {
        queue.async {
            self.ensureInitialized { initResult in
                switch initResult {
                case .success:
                    self.send(method: "account/rateLimits/read", params: Optional<EmptyParams>.none) { result in
                        switch result {
                        case .success(let data):
                            do {
                                AppLog.write("rateLimits raw: \(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
                                let response = try JSONDecoder().decode(GetAccountRateLimitsResponse.self, from: data)
                                AppLog.write("rateLimits decoded primary=\(response.preferredSnapshot.primary?.usedPercent ?? -1) secondary=\(response.preferredSnapshot.secondary?.usedPercent ?? -1)")
                                completion(.success(response.preferredSnapshot))
                            } catch {
                                AppLog.write("rateLimits decode failed: \(error)")
                                completion(.failure(CodexAppServerError.invalidResponse))
                            }
                        case .failure(let error):
                            AppLog.write("rateLimits request failed: \(error.localizedDescription)")
                            completion(.failure(error))
                        }
                    }
                case .failure(let error):
                    AppLog.write("initialize failed before rateLimits: \(error.localizedDescription)")
                    completion(.failure(error))
                }
            }
        }
    }

    func readAttentionState(completion: @escaping (Result<CodexAttentionState, Error>) -> Void) {
        queue.async {
            self.ensureInitialized { initResult in
                switch initResult {
                case .success:
                    self.send(method: "thread/loaded/list", params: ThreadLoadedListParams(limit: 50)) { result in
                        switch result {
                        case .success(let data):
                            do {
                                let response = try JSONDecoder().decode(ThreadLoadedListResponse.self, from: data)
                                if response.data.isEmpty {
                                    self.readRecentThreadStatuses(completion: completion)
                                } else {
                                    self.readThreadStatuses(threadIds: response.data, completion: completion)
                                }
                            } catch {
                                AppLog.write("thread loaded list decode failed: \(error)")
                                completion(.failure(CodexAppServerError.invalidResponse))
                            }
                        case .failure(let error):
                            AppLog.write("thread loaded list failed: \(error.localizedDescription)")
                            completion(.failure(error))
                        }
                    }
                case .failure(let error):
                    AppLog.write("initialize failed before attention read: \(error.localizedDescription)")
                    completion(.failure(error))
                }
            }
        }
    }

    /// Executable files named `codex` inside an app bundle, newest first.
    private static func bundledExecutables(inApp appPath: String) -> [String] {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: appPath).appendingPathComponent("Contents")
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: []
        ) else { return [] }

        var found: [(path: String, date: Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "codex",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  fileManager.isExecutableFile(atPath: url.path) else { continue }
            found.append((url.path, values.contentModificationDate ?? .distantPast))
        }
        return found.sorted { $0.date > $1.date }.map(\.path)
    }

    private func startLocked() -> Bool {
        guard process == nil else { return true }
        guard let executable = Self.locateExecutable() else {
            return false
        }

        stdout = Pipe()
        stdin = Pipe()
        stderr = Pipe()
        buffer.removeAll()
        lastStderr = ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        // GUI apps get a minimal PATH; a CLI install of codex may be a Node
        // script that needs `node` from Homebrew or similar.
        var environment = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin"
        environment["PATH"] = extraPath + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            // Give the stderr handler a moment to deliver the final message.
            self?.queue.asyncAfter(deadline: .now() + 0.3) {
                guard let self else { return }
                let detail = self.lastStderr
                AppLog.write("codex app-server exited status=\(status) stderr=\(detail)")
                self.initialized = false
                self.initializing = false
                self.process = nil
                let lastLine = detail.split(separator: "\n").last.map(String.init) ?? "退出码 \(status)"
                let error = CodexAppServerError.rpcError("Codex 服务已退出：\(lastLine)")
                let callbacks = self.pending
                self.pending.removeAll()
                callbacks.values.forEach { $0(.failure(error)) }
            }
        }

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                self?.buffer.append(data)
                self?.consumeFrames()
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.queue.async {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    self?.lastStderr = trimmed
                    AppLog.write("codex stderr: \(trimmed)")
                }
            }
        }

        do {
            try process.run()
            self.process = process
            return true
        } catch {
            self.process = nil
            return false
        }
    }

    private func ensureInitialized(completion: @escaping (Result<Void, Error>) -> Void) {
        if initialized {
            completion(.success(()))
            return
        }

        initializationCallbacks.append(completion)
        guard !initializing else { return }

        guard startLocked() else {
            let callbacks = initializationCallbacks
            initializationCallbacks.removeAll()
            callbacks.forEach { $0(.failure(CodexAppServerError.codexExecutableMissing)) }
            return
        }

        initializing = true
        let params = InitializeParams(
            clientInfo: ClientInfo(name: "codex-quota-menubar", title: "Codex Quota Bar", version: "0.1.0"),
            capabilities: InitializeCapabilities(experimentalApi: true)
        )
        send(method: "initialize", params: params) { [weak self] result in
            guard let self else { return }
            self.initializing = false
            if case .success = result {
                self.initialized = true
                AppLog.write("initialize succeeded")
            } else if case .failure(let error) = result {
                AppLog.write("initialize failed: \(error.localizedDescription)")
            }
            let callbacks = self.initializationCallbacks
            self.initializationCallbacks.removeAll()
            callbacks.forEach { callback in
                switch result {
                case .success:
                    callback(.success(()))
                case .failure(let error):
                    callback(.failure(error))
                }
            }
        }
    }

    private func send<T: Encodable>(method: String, params: T?, completion: @escaping (Result<Data, Error>) -> Void) {
        guard process != nil else {
            completion(.failure(CodexAppServerError.processNotRunning))
            return
        }

        let id = nextID
        nextID += 1
        pending[id] = completion

        let request = JSONRPCRequest(id: id, method: method, params: params)
        do {
            let body = try JSONEncoder().encode(request)
            var line = body
            line.append(Data("\n".utf8))
            stdin.fileHandleForWriting.write(line)
        } catch {
            pending.removeValue(forKey: id)
            completion(.failure(error))
        }

        queue.asyncAfter(deadline: .now() + 60) {
            if let callback = self.pending.removeValue(forKey: id) {
                callback(.failure(CodexAppServerError.timeout))
            }
        }
    }

    private func consumeFrames() {
        while let range = buffer.range(of: Data("\n".utf8)) {
            let line = buffer[..<range.lowerBound]
            buffer.removeSubrange(...range.lowerBound)
            guard !line.isEmpty else { continue }
            handleMessage(Data(line))
        }
    }

    private func handleMessage(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(JSONRPCEnvelope.self, from: data) else { return }
        guard let id = envelope.id, let callback = pending.removeValue(forKey: id) else { return }

        if let error = envelope.error {
            AppLog.write("rpc error id=\(id): \(error.message)")
            callback(.failure(CodexAppServerError.rpcError(error.message)))
            return
        }

        guard let result = envelope.result else {
            AppLog.write("rpc invalid response id=\(id)")
            callback(.failure(CodexAppServerError.invalidResponse))
            return
        }

        callback(.success(result))
    }

    private func readThreadStatuses(threadIds: [String], completion: @escaping (Result<CodexAttentionState, Error>) -> Void) {
        guard !threadIds.isEmpty else {
            readRecentThreadStatuses(completion: completion)
            return
        }

        var remaining = threadIds.count
        var waitingApprovalCount = 0
        var waitingInputCount = 0
        var firstError: Error?

        for threadId in threadIds {
            let params = ThreadReadParams(threadId: threadId, includeTurns: false)
            send(method: "thread/read", params: params) { result in
                switch result {
                case .success(let data):
                    do {
                        let response = try JSONDecoder().decode(ThreadReadResponse.self, from: data)
                        if response.thread.status.activeFlags.contains(.waitingOnApproval) {
                            waitingApprovalCount += 1
                        }
                        if response.thread.status.activeFlags.contains(.waitingOnUserInput) {
                            waitingInputCount += 1
                        }
                    } catch {
                        AppLog.write("thread read decode failed for \(threadId): \(error)")
                        if firstError == nil {
                            firstError = CodexAppServerError.invalidResponse
                        }
                    }
                case .failure(let error):
                    AppLog.write("thread read failed for \(threadId): \(error.localizedDescription)")
                    if firstError == nil {
                        firstError = error
                    }
                }

                remaining -= 1
                guard remaining == 0 else { return }

                if waitingApprovalCount > 0 || waitingInputCount > 0 || firstError == nil {
                    completion(.success(CodexAttentionState(
                        waitingApprovalCount: waitingApprovalCount,
                        waitingInputCount: waitingInputCount
                    )))
                } else {
                    completion(.failure(firstError ?? CodexAppServerError.invalidResponse))
                }
            }
        }
    }

    private func readRecentThreadStatuses(completion: @escaping (Result<CodexAttentionState, Error>) -> Void) {
        send(method: "thread/list", params: ThreadListParams(limit: 50)) { result in
            switch result {
            case .success(let data):
                do {
                    let response = try JSONDecoder().decode(ThreadListResponse.self, from: data)
                    completion(.success(Self.attentionState(from: response.data.map(\.status))))
                } catch {
                    AppLog.write("thread list decode failed: \(error)")
                    completion(.failure(CodexAppServerError.invalidResponse))
                }
            case .failure(let error):
                AppLog.write("thread list failed: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    private static func attentionState(from statuses: [CodexThreadStatus]) -> CodexAttentionState {
        CodexAttentionState(
            waitingApprovalCount: statuses.filter { $0.activeFlags.contains(.waitingOnApproval) }.count,
            waitingInputCount: statuses.filter { $0.activeFlags.contains(.waitingOnUserInput) }.count
        )
    }
}

private struct JSONRPCRequest<T: Encodable>: Encodable {
    let id: Int
    let method: String
    let params: T?

    enum CodingKeys: String, CodingKey {
        case id
        case method
        case params
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        if let params {
            try container.encode(params, forKey: .params)
        } else {
            try container.encodeNil(forKey: .params)
        }
    }
}

private struct JSONRPCEnvelope: Decodable {
    let id: Int?
    let result: Data?
    let error: JSONRPCError?

    enum CodingKeys: String, CodingKey {
        case id
        case result
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        error = try container.decodeIfPresent(JSONRPCError.self, forKey: .error)
        if container.contains(.result) {
            result = try RawJSON.extract(from: container, forKey: .result)
        } else {
            result = nil
        }
    }
}

private struct RawJSON: Encodable {
    let value: Any

    static func extract<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) throws -> Data {
        let value = try container.decode(AnyDecodable.self, forKey: key).value
        if JSONSerialization.isValidJSONObject(value) {
            return try JSONSerialization.data(withJSONObject: value, options: [])
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }

    func encode(to encoder: Encoder) throws {}
}

private struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyDecodable].self) {
            value = array.map(\.value)
        } else if let dictionary = try? container.decode([String: AnyDecodable].self) {
            value = dictionary.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }
}

private struct JSONRPCError: Decodable {
    let message: String
}

private struct EmptyParams: Encodable {}

private struct ThreadLoadedListParams: Encodable {
    let limit: Int
}

private struct ThreadLoadedListResponse: Decodable {
    let data: [String]
}

private struct ThreadReadParams: Encodable {
    let threadId: String
    let includeTurns: Bool
}

private struct ThreadReadResponse: Decodable {
    let thread: CodexThread
}

private struct ThreadListParams: Encodable {
    let limit: Int
}

private struct ThreadListResponse: Decodable {
    let data: [CodexThread]
}

private struct CodexThread: Decodable {
    let status: CodexThreadStatus
}

private struct CodexThreadStatus: Decodable {
    let type: String
    let activeFlags: [CodexThreadActiveFlag]

    enum CodingKeys: String, CodingKey {
        case type
        case activeFlags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        activeFlags = try container.decodeIfPresent([CodexThreadActiveFlag].self, forKey: .activeFlags) ?? []
    }
}

private enum CodexThreadActiveFlag: String, Decodable {
    case waitingOnApproval
    case waitingOnUserInput
}

private struct InitializeParams: Encodable {
    let clientInfo: ClientInfo
    let capabilities: InitializeCapabilities
}

private struct ClientInfo: Encodable {
    let name: String
    let title: String
    let version: String
}

private struct InitializeCapabilities: Encodable {
    let experimentalApi: Bool
}
