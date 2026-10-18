import Foundation

enum CategoryColor: String, Codable, CaseIterable, Sendable {
    case teal, blue, purple, orange, pink, green, indigo, brown
}

struct TimeCategory: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var color: CategoryColor
}

struct TimeEntry: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var start: Date
    var end: Date
    var note: String
    var categoryID: UUID
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct LedgerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct TimeLedger: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var categories: [TimeCategory] = [
        TimeCategory(name: "工作", color: .teal),
        TimeCategory(name: "阅读", color: .blue),
        TimeCategory(name: "睡觉", color: .purple),
        TimeCategory(name: "其他", color: .orange)
    ]
    var entries: [TimeEntry] = []

    mutating func saveEntry(_ entry: TimeEntry, now: Date = Date()) throws {
        guard entry.start.timeIntervalSince1970.isFinite, entry.end.timeIntervalSince1970.isFinite,
              entry.end > entry.start else { throw LedgerError("结束时间必须晚于开始时间。") }
        guard entry.end <= now else { throw LedgerError("只能记录已经发生的时间，请调整结束时间。") }
        guard categories.contains(where: { $0.id == entry.categoryID }) else { throw LedgerError("请选择一个有效分类。") }
        guard !entries.contains(where: { $0.id != entry.id && $0.start < entry.end && entry.start < $0.end }) else {
            throw LedgerError("这段时间与已有记录重叠，请调整起止时间。")
        }
        var normalized = entry
        normalized.note = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = normalized }
        else { entries.append(normalized) }
    }

    mutating func deleteEntry(_ id: UUID) { entries.removeAll { $0.id == id } }

    mutating func saveCategory(_ category: TimeCategory) throws {
        var normalized = category
        normalized.name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.name.isEmpty else { throw LedgerError("分类名称不能为空。") }
        guard normalized.name.count <= 24 else { throw LedgerError("分类名称最多 24 个字。") }
        guard !categories.contains(where: { $0.id != category.id && $0.name.localizedCaseInsensitiveCompare(normalized.name) == .orderedSame }) else {
            throw LedgerError("已存在同名分类，请换一个名称。")
        }
        if let index = categories.firstIndex(where: { $0.id == category.id }) { categories[index] = normalized }
        else { categories.append(normalized) }
    }

    mutating func deleteCategory(_ id: UUID, replacement: UUID?) throws {
        guard categories.contains(where: { $0.id == id }) else { throw LedgerError("分类不存在。") }
        guard categories.count > 1 else { throw LedgerError("至少需要保留一个分类。") }
        if entries.contains(where: { $0.categoryID == id }) {
            guard let replacement, replacement != id, categories.contains(where: { $0.id == replacement }) else {
                throw LedgerError("请先选择历史记录要迁移到的分类。")
            }
            for index in entries.indices where entries[index].categoryID == id { entries[index].categoryID = replacement }
        }
        categories.removeAll { $0.id == id }
    }

    /// Validate a decoded file before allowing it to become writable app state.
    func validate() throws {
        guard schemaVersion == 1 else { throw LedgerError("此数据版本暂不支持，请更新 App。原文件已保留。") }
        guard !categories.isEmpty,
              Set(categories.map(\.id)).count == categories.count,
              Set(entries.map(\.id)).count == entries.count else { throw LedgerError("本地数据结构异常，原文件已保留。") }
        var checked = TimeLedger()
        checked.categories = []
        for category in categories { try checked.saveCategory(category) }
        let ids = Set(categories.map(\.id))
        let sorted = entries.sorted { $0.start < $1.start }
        var previousEnd: Date?
        for entry in sorted {
            guard entry.start.timeIntervalSince1970.isFinite, entry.end.timeIntervalSince1970.isFinite,
                  entry.end > entry.start, ids.contains(entry.categoryID),
                  previousEnd.map({ $0 <= entry.start }) ?? true else {
                throw LedgerError("本地记录时间或分类异常，原文件已保留。")
            }
            previousEnd = entry.end
        }
    }
}
