import Foundation

struct AnalysisResponse: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let runID: String
    let answer: String
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", runID = "run_id", answer }
}

protocol AgentAnalyzing: Sendable {
    func analyze(question: String, snapshot: AnalysisSnapshot) async throws -> AnalysisResponse
}

enum AgentClientError: LocalizedError, Equatable, Sendable {
    case transport(URLError.Code)
    case invalidResponse
    case server(code: String, message: String, retryable: Bool, runID: String?)

    var errorDescription: String? {
        switch self {
        case .transport(.timedOut): return "分析超时，请重试。"
        case .transport: return "未连接到本机分析服务，请确认 selfweave-server 已启动。"
        case .invalidResponse: return "分析服务返回了无法识别的结果，请检查服务版本后重试。"
        case .server(_, let message, _, _): return message
        }
    }
    var retryable: Bool {
        if case .server(_, _, let retryable, _) = self { return retryable }
        return true
    }
    var runID: String? {
        if case .server(_, _, _, let runID) = self { return runID }
        return nil
    }
}

struct AgentClient: AgentAnalyzing {
    let session: URLSession
    let baseURL: URL
    init(session: URLSession = .shared, baseURL: URL = URL(string: "http://127.0.0.1:8787")!) {
        self.session = session
        self.baseURL = baseURL
    }

    func analyze(question: String, snapshot: AnalysisSnapshot) async throws -> AnalysisResponse {
        struct Request: Encodable {
            let schema_version = 1
            let question: String
            let snapshot: AnalysisSnapshot
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/analysis"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 35
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = try JSONEncoder().encode(Request(question: question, snapshot: snapshot))
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AgentClientError.transport(error.code)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, data.count <= 4 * 1024 * 1024 else { throw AgentClientError.invalidResponse }
        let decoder = JSONDecoder()
        if http.statusCode == 200 {
            guard let result = try? decoder.decode(AnalysisResponse.self, from: data), result.schemaVersion == 1,
                  !result.runID.isEmpty, !result.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentClientError.invalidResponse
            }
            return result
        }
        struct Failure: Decodable {
            struct Detail: Decodable { let code: String; let message: String; let retryable: Bool }
            let schema_version: Int
            let run_id: String?
            let error: Detail
        }
        guard let failure = try? decoder.decode(Failure.self, from: data), failure.schema_version == 1,
              !failure.error.message.isEmpty else { throw AgentClientError.invalidResponse }
        throw AgentClientError.server(code: failure.error.code, message: failure.error.message, retryable: failure.error.retryable, runID: failure.run_id)
    }
}
