import Foundation

struct LedgerFile {
    let url: URL

    func load() throws -> TimeLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return TimeLedger() }
        let ledger = try JSONDecoder().decode(TimeLedger.self, from: Data(contentsOf: url))
        try ledger.validate()
        return ledger
    }

    func save(_ ledger: TimeLedger) throws {
        try ledger.validate()
        let data = try JSONEncoder().encode(ledger)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
