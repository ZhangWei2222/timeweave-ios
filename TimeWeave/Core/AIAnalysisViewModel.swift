import Foundation
import Combine

@MainActor
final class AIAnalysisViewModel: ObservableObject {
    @Published var question = "分析这段时间的分配，指出最值得先关注的一点。"
    @Published private(set) var isLoading = false
    @Published private(set) var response: AnalysisResponse?
    @Published private(set) var error: AgentClientError?
    private let client: any AgentAnalyzing
    private let snapshotBuilder: @MainActor () throws -> AnalysisSnapshot
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(client: any AgentAnalyzing = AgentClient(), snapshotBuilder: @escaping @MainActor () throws -> AnalysisSnapshot) {
        self.client = client
        self.snapshotBuilder = snapshotBuilder
    }
    var canSubmit: Bool {
        let count = question.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
        return !isLoading && (1...500).contains(count)
    }
    func submit() {
        guard canSubmit else { return }
        let snapshot: AnalysisSnapshot
        do { snapshot = try snapshotBuilder() }
        catch { self.error = .server(code: "snapshot_invalid", message: "无法生成统计快照，请检查本地记录。", retryable: false, runID: nil); return }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID()
        generation = id
        isLoading = true
        response = nil
        error = nil
        task = Task { [weak self, client] in
            do {
                let result = try await client.analyze(question: question, snapshot: snapshot)
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.response = result
            } catch {
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.error = (error as? AgentClientError) ?? .invalidResponse
            }
            guard let self, self.generation == id else { return }
            self.isLoading = false
            self.task = nil
        }
    }
    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
    }
}
