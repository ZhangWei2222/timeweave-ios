import XCTest
@testable import TimeWeaveCore

final class LedgerTests: XCTestCase {
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    var now: Date { date("2026-10-16T12:00:00Z") }
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
    func entry(_ start: String, _ end: String, category: UUID) -> TimeEntry {
        TimeEntry(start: date(start), end: date(end), note: "测试", categoryID: category)
    }
    func testOverlapRejectsButAdjacentAndSelfEditAreAllowed() throws {
        var ledger = TimeLedger()
        let cat = ledger.categories[0].id
        var first = entry("2026-10-16T09:00:00Z", "2026-10-16T10:00:00Z", category: cat)
        try ledger.saveEntry(first, now: now)
        first.note = "修改描述"
        try ledger.saveEntry(first, now: now)
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.entries[0].note, "修改描述")
        try ledger.saveEntry(entry("2026-10-16T10:00:00Z", "2026-10-16T11:00:00Z", category: cat), now: now)
        first.end = date("2026-10-16T10:01:00Z")
        XCTAssertThrowsError(try ledger.saveEntry(first, now: now))
        XCTAssertEqual(ledger.entries[0].end, date("2026-10-16T10:00:00Z"))
        XCTAssertThrowsError(try ledger.saveEntry(entry("2026-10-16T08:00:00Z", "2026-10-16T12:00:00Z", category: cat), now: now))
    }
    func testInvalidAndFutureTimesAndUnknownCategoryRejected() {
        var ledger = TimeLedger()
        let cat = ledger.categories[0].id
        for pair in [("12:00", "12:00"), ("12:00", "11:00"), ("12:00", "13:00")] {
            XCTAssertThrowsError(try ledger.saveEntry(entry("2026-10-16T\(pair.0):00Z", "2026-10-16T\(pair.1):00Z", category: cat), now: now))
        }
        XCTAssertThrowsError(try ledger.saveEntry(entry("2026-10-16T09:00:00Z", "2026-10-16T10:00:00Z", category: UUID()), now: now))
        XCTAssertTrue(ledger.entries.isEmpty)
    }
    func testCrossMidnightClipsAndMidnightEndDoesNotLeak() throws {
        var ledger = TimeLedger()
        try ledger.saveEntry(entry("2026-10-14T23:00:00Z", "2026-10-15T01:00:00Z", category: ledger.categories[0].id), now: now)
        let days = TimeStatistics.days(ending: date("2026-10-16T12:00:00Z"), count: 3, calendar: calendar)
        XCTAssertEqual(days.map { TimeStatistics.seconds(ledger.entries, in: $0) }, [3600, 3600, 0])
        let midnight = entry("2026-10-14T23:00:00Z", "2026-10-15T00:00:00Z", category: ledger.categories[0].id)
        XCTAssertEqual(TimeStatistics.seconds([midnight], in: days[1]), 0)
    }
    func testHourBucketsSplitPartialHoursAndCategoryFilter() {
        let cat = UUID()
        let other = UUID()
        let entries = [entry("2026-10-16T09:30:00Z", "2026-10-16T10:30:00Z", category: cat), entry("2026-10-16T11:00:00Z", "2026-10-16T12:00:00Z", category: other)]
        let range = calendar.dateInterval(of: .day, for: now)!
        let buckets = TimeStatistics.hourly(entries, in: range, categoryID: cat, calendar: calendar)
        XCTAssertEqual(buckets.count, 24)
        XCTAssertEqual(buckets[9], 1800)
        XCTAssertEqual(buckets[10], 1800)
        XCTAssertEqual(buckets[11], 0)
        XCTAssertEqual(buckets.reduce(0, +), 3600)
    }
    func testDaylightSavingDaysAndRepeatedHourPreserveElapsedTime() {
        var cal = calendar
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let spring = TimeStatistics.days(ending: date("2026-03-08T19:00:00Z"), count: 1, calendar: cal)[0]
        let autumn = TimeStatistics.days(ending: date("2026-11-01T20:00:00Z"), count: 1, calendar: cal)[0]
        XCTAssertEqual(spring.duration, 23 * 3600)
        XCTAssertEqual(autumn.duration, 25 * 3600)
        let cat = UUID()
        let entire = TimeEntry(start: autumn.start, end: autumn.end, note: "", categoryID: cat)
        let hours = TimeStatistics.hourly([entire], in: autumn, categoryID: cat, calendar: cal)
        XCTAssertEqual(hours[1], 7200)
        XCTAssertEqual(hours.reduce(0, +), 25 * 3600)
    }
    func testCategoryMigrationRenameAndDeletionPreserveRecords() throws {
        var ledger = TimeLedger()
        let source = ledger.categories[0].id
        let target = ledger.categories[1].id
        try ledger.saveEntry(entry("2026-10-16T09:00:00Z", "2026-10-16T10:00:00Z", category: source), now: now)
        XCTAssertThrowsError(try ledger.deleteCategory(source, replacement: nil))
        try ledger.deleteCategory(source, replacement: target)
        XCTAssertEqual(ledger.entries[0].categoryID, target)
        XCTAssertEqual(ledger.entries[0].end.timeIntervalSince(ledger.entries[0].start), 3600)
        var category = ledger.categories[0]
        category.name = "  学习  "
        try ledger.saveCategory(category)
        XCTAssertEqual(ledger.categories[0].name, "学习")
        XCTAssertThrowsError(try ledger.saveCategory(TimeCategory(name: "学习", color: .teal)))
        XCTAssertThrowsError(try ledger.saveCategory(TimeCategory(name: " \n ", color: .teal)))
        for c in ledger.categories.filter({ $0.id != target }) { try ledger.deleteCategory(c.id, replacement: target) }
        XCTAssertThrowsError(try ledger.deleteCategory(target, replacement: nil))
        ledger.deleteEntry(ledger.entries[0].id)
        XCTAssertTrue(ledger.entries.isEmpty)
    }
    func testAtomicPersistenceRoundTripAndCorruptFilePreserved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ledger.json")
        let file = LedgerFile(url: url)
        var ledger = try file.load()
        try ledger.saveEntry(entry("2026-10-16T09:00:00Z", "2026-10-16T10:00:00Z", category: ledger.categories[0].id), now: now)
        try file.save(ledger)
        XCTAssertEqual(try LedgerFile(url: url).load(), ledger)
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try file.load())
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
    func testUnknownSchemaAndInvalidReferencesRejected() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ledger.json")
        var ledger = TimeLedger()
        ledger.schemaVersion = 99
        try JSONEncoder().encode(ledger).write(to: url)
        XCTAssertThrowsError(try LedgerFile(url: url).load())
        ledger.schemaVersion = 1
        ledger.entries = [entry("2026-10-16T09:00:00Z", "2026-10-16T10:00:00Z", category: UUID())]
        try JSONEncoder().encode(ledger).write(to: url)
        XCTAssertThrowsError(try LedgerFile(url: url).load())
    }
    func testWriteFailureIsSurfaced() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try LedgerFile(url: url.appendingPathComponent("ledger.json")).save(TimeLedger()))
    }
}
