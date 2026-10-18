import Foundation

enum TimeStatistics {
    static func seconds(_ entries: [TimeEntry], in interval: DateInterval, categoryID: UUID? = nil) -> TimeInterval {
        entries.reduce(0) { total, entry in
            guard categoryID == nil || entry.categoryID == categoryID else { return total }
            return total + max(0, min(entry.end, interval.end).timeIntervalSince(max(entry.start, interval.start)))
        }
    }

    static func days(ending date: Date, count: Int, calendar: Calendar = .current) -> [DateInterval] {
        guard count > 0 else { return [] }
        let endDay = calendar.startOfDay(for: date)
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: endDay) else { return nil }
            return calendar.dateInterval(of: .day, for: day)
        }
    }

    /// Walk real calendar-hour boundaries so missing and repeated DST hours keep their duration.
    static func hourly(_ entries: [TimeEntry], in interval: DateInterval, categoryID: UUID? = nil, calendar: Calendar = .current) -> [TimeInterval] {
        var buckets = Array(repeating: 0.0, count: 24)
        for entry in entries where categoryID == nil || entry.categoryID == categoryID {
            var cursor = max(entry.start, interval.start)
            let end = min(entry.end, interval.end)
            while cursor < end {
                guard let hour = calendar.dateInterval(of: .hour, for: cursor), hour.end > cursor else { break }
                let stop = min(end, hour.end)
                buckets[calendar.component(.hour, from: cursor)] += stop.timeIntervalSince(cursor)
                cursor = stop
            }
        }
        return buckets
    }
}
