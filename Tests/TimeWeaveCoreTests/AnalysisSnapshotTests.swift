import XCTest
@testable import TimeWeaveCore

final class AnalysisSnapshotTests: XCTestCase {
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        return result
    }

    func testSnapshotClipsMidnightAndOmitsPrivateFields() throws {
        var ledger = TimeLedger()
        let category = ledger.categories[0].id
        ledger.entries = [TimeEntry(start: date("2026-10-20T15:30:00Z"), end: date("2026-10-20T16:30:00Z"), note: "private-secret-note", categoryID: category)]
        let snapshot = try AnalysisSnapshotBuilder.build(ledger: ledger, period: 7, now: date("2026-10-21T12:00:00Z"), calendar: calendar())
        XCTAssertEqual(snapshot.range.startDate, "2026-10-15")
        XCTAssertEqual(snapshot.range.endDateExclusive, "2026-10-22")
        XCTAssertEqual(snapshot.totalMinutes, 60)
        XCTAssertEqual(snapshot.categories.map(\.minutes), [60])
        XCTAssertEqual(snapshot.days.map(\.minutes), [0, 0, 0, 0, 0, 30, 30])
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        for secret in ["private-secret-note", "note", "category_id", category.uuidString, "entries"] {
            XCTAssertFalse(json.contains(secret))
        }
        XCTAssertTrue(json.contains("end_date_exclusive"))
    }

    func testEmptyThirtyDaySnapshotAndMinuteConservation() throws {
        var ledger = TimeLedger()
        let now = date("2026-10-21T12:00:00Z")
        let empty = try AnalysisSnapshotBuilder.build(ledger: ledger, period: 30, now: now, calendar: calendar())
        XCTAssertEqual(empty.days.count, 30)
        XCTAssertEqual(empty.totalMinutes, 0)
        XCTAssertEqual(empty.categories, [])
        ledger.entries = [TimeEntry(start: date("2026-10-20T15:59:30Z"), end: date("2026-10-20T16:01:10Z"), note: "", categoryID: ledger.categories[0].id)]
        let snapshot = try AnalysisSnapshotBuilder.build(ledger: ledger, period: 7, now: now, calendar: calendar())
        XCTAssertEqual(snapshot.totalMinutes, 1)
        XCTAssertEqual(snapshot.categories.reduce(0) { $0 + $1.minutes }, 1)
        XCTAssertEqual(snapshot.days.reduce(0) { $0 + $1.minutes }, 1)
        XCTAssertThrowsError(try AnalysisSnapshotBuilder.build(ledger: ledger, period: 0, now: now, calendar: calendar()))
    }

    func testDSTDaysPreserveRealMinutes() throws {
        let cal = calendar("America/Los_Angeles")
        for (nowText, expected) in [("2026-03-08T19:00:00Z", 1380), ("2026-11-01T20:00:00Z", 1500)] {
            let now = date(nowText)
            let day = cal.dateInterval(of: .day, for: now)!
            var ledger = TimeLedger()
            ledger.entries = [TimeEntry(start: day.start, end: day.end, note: "", categoryID: ledger.categories[0].id)]
            let result = try AnalysisSnapshotBuilder.build(ledger: ledger, period: 7, now: now, calendar: cal)
            XCTAssertEqual(result.totalMinutes, expected)
            XCTAssertEqual(result.days.last?.minutes, expected)
        }
    }
}
