import Foundation

final class ApprovalLogMonitor {
    private let sessionsPath = "\(NSHomeDirectory())/.codex/sessions"
    private let maxFileAge: TimeInterval = 60 * 60
    private let maxFiles = 8
    private let maxReadBytes: UInt64 = 1024 * 1024
    private var lastPendingApprovalCount = -1

    func readPendingApproval(completion: @escaping (CodexAttentionState) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let state = self.readPendingApproval()
            self.logIfChanged(state)
            completion(state)
        }
    }

    private func readPendingApproval() -> CodexAttentionState {
        let files = recentSessionFiles()
        guard !files.isEmpty else { return .none }

        var requested = Set<String>()
        var resolved = Set<String>()

        for file in files {
            for line in recentLines(from: file) {
                guard let payload = payload(from: line),
                      let type = payload["type"] as? String else {
                    continue
                }

                if type == "function_call",
                   let callID = payload["call_id"] as? String,
                   let arguments = payload["arguments"] as? String,
                   arguments.contains(#""sandbox_permissions":"require_escalated""#) {
                    requested.insert(callID)
                } else if type == "function_call_output",
                          let callID = payload["call_id"] as? String {
                    resolved.insert(callID)
                }
            }
        }

        return CodexAttentionState(
            waitingApprovalCount: requested.subtracting(resolved).count,
            waitingInputCount: 0
        )
    }

    private func recentSessionFiles() -> [URL] {
        let root = URL(fileURLWithPath: sessionsPath)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let cutoff = Date().addingTimeInterval(-maxFileAge)
        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  modified >= cutoff else {
                continue
            }
            files.append((url, modified))
        }

        return files
            .sorted { $0.modified > $1.modified }
            .prefix(maxFiles)
            .map(\.url)
    }

    private func recentLines(from url: URL) -> [Substring] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let size = handle.seekToEndOfFile()
        let offset = size > maxReadBytes ? size - maxReadBytes : 0
        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard var text = String(data: data, encoding: .utf8) else { return [] }
        if offset > 0, let firstNewline = text.firstIndex(of: "\n") {
            text.removeSubrange(...firstNewline)
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
    }

    private func payload(from line: Substring) -> [String: Any]? {
        guard let data = String(line).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["payload"] as? [String: Any]
    }

    private func logIfChanged(_ state: CodexAttentionState) {
        guard state.waitingApprovalCount != lastPendingApprovalCount else { return }
        lastPendingApprovalCount = state.waitingApprovalCount
        AppLog.write("approval session pending approvals=\(state.waitingApprovalCount)")
    }
}
