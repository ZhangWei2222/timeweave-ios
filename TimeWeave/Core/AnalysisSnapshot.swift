import Foundation

struct AnalysisSnapshot: Codable, Equatable, Sendable {
    struct Range: Codable, Equatable, Sendable {
        let startDate: String
        let endDateExclusive: String
        let timezone: String
        enum CodingKeys: String, CodingKey {
            case startDate = "start_date", endDateExclusive = "end_date_exclusive", timezone
        }
    }
    struct Category: Codable, Equatable, Sendable {
        let name: String
        let minutes: Int
    }
    struct Day: Codable, Equatable, Sendable {
        let date: String
        let minutes: Int
    }
    let range: Range
    let totalMinutes: Int
    let categories: [Category]
    let days: [Day]
    enum CodingKeys: String, CodingKey {
        case range, totalMinutes = "total_minutes", categories, days
    }
}
