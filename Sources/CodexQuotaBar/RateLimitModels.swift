import Foundation

struct GetAccountRateLimitsResponse: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?

    var preferredSnapshot: RateLimitSnapshot {
        rateLimitsByLimitId?["codex"] ?? rateLimits
    }
}

struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

struct RateLimitWindow: Decodable {
    let usedPercent: Int
    let resetsAt: Int64?
    let windowDurationMins: Int64?

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }
}

struct QuotaDisplayModel {
    let primary: WindowDisplay
    let secondary: WindowDisplay
    let error: String?

    init(snapshot: RateLimitSnapshot?, error: String?) {
        self.error = error
        primary = WindowDisplay(title: "5小时", window: snapshot?.primary)
        secondary = WindowDisplay(title: "周限额", window: snapshot?.secondary)
    }

    var menuTitle: String {
        if primary.hasValue {
            return "Codex \(primary.remainingText)"
        }
        return "Codex --%"
    }

    var statusTitle: String {
        primary.remainingText
    }
}

struct WindowDisplay {
    let title: String
    let remaining: Int?
    let used: Int?
    let resetText: String

    init(title: String, window: RateLimitWindow?) {
        self.title = title
        remaining = window?.remainingPercent
        used = window?.usedPercent
        resetText = Self.formatReset(window?.resetsAt)
    }

    var hasValue: Bool {
        remaining != nil
    }

    var remainingText: String {
        guard let remaining else { return "--%" }
        return "\(remaining)%"
    }

    private static func formatReset(_ rawTimestamp: Int64?) -> String {
        guard let rawTimestamp else { return "--:--" }
        let seconds = rawTimestamp > 10_000_000_000 ? Double(rawTimestamp) / 1000 : Double(rawTimestamp)
        let date = Date(timeIntervalSince1970: seconds)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d HH:mm"
        return formatter.string(from: date)
    }
}
