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
            return "找不到 Codex.app"
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
    private let executable = "/Applications/Codex.app/Contents/Resources/codex"
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

    private func startLocked() -> Bool {
        guard process == nil else { return true }
        guard FileManager.default.isExecutableFile(atPath: executable) else { return false }

        stdout = Pipe()
        stdin = Pipe()
        stderr = Pipe()
        buffer.removeAll()
        lastStderr = ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] _ in
            self?.queue.async {
                self?.initialized = false
                self?.initializing = false
                self?.process = nil
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
                self?.lastStderr = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
