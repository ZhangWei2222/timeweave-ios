import XCTest
@testable import TimeWeaveCore

@MainActor
final class AIAnalysisViewModelTests: XCTestCase {
    func testRetryRebuildsSnapshotAndDuplicateSubmissionIsIgnored() async throws {
        let client = ControlledAnalysisClient()
        var buildCount = 0
        let vm = AIAnalysisViewModel(client: client) {
            buildCount += 1
            return try AnalysisSnapshotBuilder.build(ledger: TimeLedger(), period: 7)
        }
        vm.question = "分析"
        vm.submit(); vm.submit()
        await client.waitForCalls(1)
        XCTAssertEqual(buildCount, 1)
        client.finish(.failure(AgentClientError.transport(.cannotConnectToHost)))
        await settle()
        XCTAssertNotNil(vm.error)
        XCTAssertFalse(vm.isLoading)
        vm.submit()
        await client.waitForCalls(2)
        XCTAssertEqual(buildCount, 2)
        client.finish(.success(.init(schemaVersion: 1, runID: "r", answer: "60 分钟")))
        await settle()
        XCTAssertEqual(vm.response?.answer, "60 分钟")
        XCTAssertNil(vm.error)
    }
    func testCancelledOldRequestCannotReplaceNewAnswer() async throws {
        let client = ControlledAnalysisClient()
        let vm = AIAnalysisViewModel(client: client) { try AnalysisSnapshotBuilder.build(ledger: TimeLedger(), period: 7) }
        vm.question = "旧问题"; vm.submit()
        await client.waitForCalls(1)
        vm.cancel()
        vm.question = "新问题"; vm.submit()
        await client.waitForCalls(2)
        client.finish(.success(.init(schemaVersion: 1, runID: "new", answer: "新答案")), index: 1)
        await settle()
        client.finish(.success(.init(schemaVersion: 1, runID: "old", answer: "旧答案")), index: 0)
        await settle()
        XCTAssertEqual(vm.response?.runID, "new")
    }
    private func settle() async { for _ in 0..<20 { await Task.yield() } }
}

@MainActor
private final class ControlledAnalysisClient: AgentAnalyzing {
    var continuations: [CheckedContinuation<AnalysisResponse, Error>?] = []
    func analyze(question: String, snapshot: AnalysisSnapshot) async throws -> AnalysisResponse {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func waitForCalls(_ count: Int) async { for _ in 0..<1000 { if continuations.count >= count { return }; await Task.yield() }; XCTFail("request never started") }
    func finish(_ value: Result<AnalysisResponse, Error>, index: Int? = nil) {
        let i = index ?? (continuations.count - 1)
        continuations[i]?.resume(with: value); continuations[i] = nil
    }
}
