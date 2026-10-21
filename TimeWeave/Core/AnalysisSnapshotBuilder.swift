import Foundation

enum AnalysisSnapshotBuilder {
    static func build(ledger: TimeLedger, period: Int, now: Date = Date(), calendar: Calendar = .current) throws -> AnalysisSnapshot {
        guard [7, 30].contains(period), now.timeIntervalSince1970.isFinite else {
            throw LedgerError("请选择近 7 天或近 30 天。")
        }
        try ledger.validate()
        let days = TimeStatistics.days(ending: now, count: period, calendar: calendar)
        guard let first = days.first, let last = days.last, days.count == period else {
            throw LedgerError("无法计算统计日期范围。")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        // Derive all three aggregates from the same category × day minute cells.
        var dailyMinutes = Array(repeating: 0, count: days.count)
        var categories: [AnalysisSnapshot.Category] = []
        for category in ledger.categories {
            var total = 0
            for (index, day) in days.enumerated() {
                let seconds = TimeStatistics.seconds(ledger.entries, in: day, categoryID: category.id)
                let minutes = Int(seconds / 60)
                dailyMinutes[index] += minutes
                total += minutes
            }
            if total > 0 { categories.append(.init(name: category.name, minutes: total)) }
        }
        categories.sort { $0.minutes == $1.minutes ? $0.name < $1.name : $0.minutes > $1.minutes }
        let timezone = calendar.timeZone.identifier == "GMT" ? "Etc/GMT" : calendar.timeZone.identifier
        return AnalysisSnapshot(
            range: .init(startDate: formatter.string(from: first.start), endDateExclusive: formatter.string(from: last.end), timezone: timezone),
            totalMinutes: dailyMinutes.reduce(0, +), categories: categories,
            days: zip(days, dailyMinutes).map { .init(date: formatter.string(from: $0.0.start), minutes: $0.1) }
        )
    }
}
