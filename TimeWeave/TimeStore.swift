import SwiftUI

@MainActor
final class TimeStore: ObservableObject {
    @Published private(set) var ledger = TimeLedger()
    @Published private(set) var loadError: String?
    private let file: LedgerFile

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        file = LedgerFile(url: directory.appendingPathComponent("TimeWeave/ledger.json"))
        reload()
    }

    func reload() {
        do {
            ledger = try file.load()
            loadError = nil
        } catch {
            loadError = "无法读取本地数据。原文件已保留，不会被覆盖。\n\(error.localizedDescription)"
        }
    }

    private func update(_ action: (inout TimeLedger) throws -> Void) throws {
        guard loadError == nil else { throw LedgerError("请先重试读取本地数据。") }
        var next = ledger
        try action(&next)
        do { try file.save(next) }
        catch { throw LedgerError("保存失败，修改尚未生效，请重试。\n\(error.localizedDescription)") }
        ledger = next
    }

    func save(_ entry: TimeEntry) throws { try update { try $0.saveEntry(entry) } }
    func deleteEntry(_ id: UUID) throws { try update { $0.deleteEntry(id) } }
    func save(_ category: TimeCategory) throws { try update { try $0.saveCategory(category) } }
    func deleteCategory(_ id: UUID, replacement: UUID?) throws {
        try update { try $0.deleteCategory(id, replacement: replacement) }
    }
    func category(_ id: UUID) -> TimeCategory? { ledger.categories.first { $0.id == id } }
}
