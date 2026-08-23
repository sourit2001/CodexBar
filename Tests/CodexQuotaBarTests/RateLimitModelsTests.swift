import XCTest
@testable import CodexQuotaBar

final class RateLimitModelsTests: XCTestCase {
    func testCurrentWeeklyOnlyResponseUsesPrimaryWindow() {
        let snapshot = RateLimitSnapshot(
            limitId: "codex",
            limitName: nil,
            primary: window(usedPercent: 2, durationMinutes: 10_080),
            secondary: nil
        )

        let model = QuotaDisplayModel(snapshot: snapshot, attention: .none, error: nil)

        XCTAssertEqual(model.primary.title, "周限额")
        XCTAssertEqual(model.primary.remainingText, "98%")
        XCTAssertFalse(model.secondary.hasValue)
        XCTAssertEqual(model.statusTitle, "98%")
        XCTAssertEqual(model.menuTitle, "Codex 98%")
    }

    func testLegacyTwoWindowResponseDerivesBothLabels() {
        let snapshot = RateLimitSnapshot(
            limitId: "codex",
            limitName: nil,
            primary: window(usedPercent: 25, durationMinutes: 300),
            secondary: window(usedPercent: 40, durationMinutes: 10_080)
        )

        let model = QuotaDisplayModel(snapshot: snapshot, attention: .none, error: nil)

        XCTAssertEqual(model.primary.title, "5小时")
        XCTAssertEqual(model.secondary.title, "周限额")
        XCTAssertEqual(model.statusTitle, "75%")
    }

    func testSecondaryBecomesActiveWhenPrimaryIsMissing() {
        let snapshot = RateLimitSnapshot(
            limitId: "codex",
            limitName: nil,
            primary: nil,
            secondary: window(usedPercent: 12, durationMinutes: 1_440)
        )

        let model = QuotaDisplayModel(snapshot: snapshot, attention: .none, error: nil)

        XCTAssertEqual(model.secondary.title, "1天")
        XCTAssertEqual(model.statusTitle, "88%")
    }

    private func window(usedPercent: Int, durationMinutes: Int64) -> RateLimitWindow {
        RateLimitWindow(
            usedPercent: usedPercent,
            resetsAt: 1_787_904_120,
            windowDurationMins: durationMinutes
        )
    }
}
