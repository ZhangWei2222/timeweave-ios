import SwiftUI

@MainActor
final class TimeStore: ObservableObject {
    @Published private(set) var ledger = TimeLedger()
    @Published private(set) var loadError: String?
    private let file: LedgerFile

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
#if DEBUG
        let resetsUITestStorage = ProcessInfo.processInfo.arguments.contains("--reset-ledger-for-ui-testing")
        let relativePath = resetsUITestStorage ? "TimeWeaveUITests/ledger.json" : "TimeWeave/ledger.json"
#else
        let relativePath = "TimeWeave/ledger.json"
#endif
        let fileURL = directory.appendingPathComponent(relativePath)
        file = LedgerFile(url: fileURL)
#if DEBUG
        if resetsUITestStorage {
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            } catch {
                loadError = "无法准备 UI 测试数据。\n\(error.localizedDescription)"
                return
            }
        }
#endif
        reload()
#if DEBUG
        if resetsUITestStorage,
           loadError == nil,
           ProcessInfo.processInfo.arguments.contains("--seed-many-categories-for-ui-testing") {
            for index in 1...36 {
                ledger.categories.append(TimeCategory(name: "测试分类 \(index)", color: .blue))
            }
        }
#endif
    }

    func reload() {
        do {
            ledger = try file.load()
            loadError = nil
        } catch {
            loadError = "无法读取本地数据。原文件已保留，不会被覆盖。\n\(error.localizedDescription)"
        }
    }

    private func update<Result>(_ action: (inout TimeLedger) throws -> Result) throws -> Result {
        guard loadError == nil else { throw LedgerError("请先重试读取本地数据。") }
        var next = ledger
        let result = try action(&next)
        do { try file.save(next) }
        catch { throw LedgerError("保存失败，修改尚未生效，请重试。\n\(error.localizedDescription)") }
        ledger = next
        return result
    }

    func save(_ entry: TimeEntry) throws { try update { try $0.saveEntry(entry) } }
    func deleteEntry(_ id: UUID) throws { try update { $0.deleteEntry(id) } }
    func save(_ category: TimeCategory) throws { try update { try $0.saveCategory(category) } }
    func deleteCategory(_ id: UUID, replacement: UUID?) throws {
        try update { try $0.deleteCategory(id, replacement: replacement) }
    }
    func startTimer(at date: Date = Date()) throws {
        try update { try $0.startTimer(at: date) }
    }
    func stopTimer(at date: Date = Date()) throws -> DateInterval {
        try update { try $0.stopTimer(at: date) }
    }
    func cancelTimer() throws { try update { $0.cancelTimer() } }
    func category(_ id: UUID) -> TimeCategory? { ledger.categories.first { $0.id == id } }
}
