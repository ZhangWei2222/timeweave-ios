import Foundation

struct AnalysisResponse: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let runID: String
    let answer: String
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", runID = "run_id", answer }
}

struct AgentCapabilities: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let conversations: Bool
    let memories: Bool
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", conversations, memories }
}

struct ConversationSummary: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let updatedAt: String
    enum CodingKeys: String, CodingKey { case id = "conversation_id", title, updatedAt = "updated_at" }
}

enum ChatMessageRole: String, Codable, Equatable, Sendable { case user, assistant }

struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let turnID: String
    let role: ChatMessageRole
    let text: String
    let createdAt: String
    enum CodingKeys: String, CodingKey { case id, turnID = "turn_id", role, text, createdAt = "created_at" }
}

enum ConversationTurnStatus: String, Codable, Equatable, Sendable {
    case accepted, running, completed, paused
    case needsAttention = "needs_attention"
    case cancelled
    var isTerminal: Bool { self == .completed || self == .paused || self == .needsAttention || self == .cancelled }
}

enum UserMemoryKind: String, Codable, Equatable, Sendable { case goal, preference, constraint }
enum UserMemoryStatus: String, Codable, Equatable, Sendable { case proposed, active, rejected, deleted }
enum UserMemorySensitivity: String, Codable, Equatable, Sendable { case normal, sensitive }

struct MemoryChange: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: UserMemoryKind
    let text: String
    let status: UserMemoryStatus
    let sensitivity: UserMemorySensitivity
    enum CodingKeys: String, CodingKey { case id = "memory_id", kind, text, status, sensitivity }
}

struct ConversationTurn: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let conversationID: String
    let messageID: String
    let threadID: String
    let question: String
    let periodDays: Int
    let status: ConversationTurnStatus
    let runID: String?
    let answer: String?
    let errorCode: String?
    let errorMessage: String?
    let retryable: Bool?
    let memoryChanges: [MemoryChange]
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id = "turn_id", conversationID = "conversation_id", messageID = "message_id", threadID = "thread_id"
        case question, periodDays = "period_days", status, runID = "run_id", answer
        case errorCode = "error_code", errorMessage = "error_message", retryable
        case memoryChanges = "memory_changes", createdAt = "created_at", updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        conversationID = try values.decode(String.self, forKey: .conversationID)
        messageID = try values.decode(String.self, forKey: .messageID)
        threadID = try values.decode(String.self, forKey: .threadID)
        question = try values.decode(String.self, forKey: .question)
        periodDays = try values.decode(Int.self, forKey: .periodDays)
        status = try values.decode(ConversationTurnStatus.self, forKey: .status)
        runID = try values.decodeIfPresent(String.self, forKey: .runID)
        answer = try values.decodeIfPresent(String.self, forKey: .answer)
        errorCode = try values.decodeIfPresent(String.self, forKey: .errorCode)
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
        retryable = try values.decodeIfPresent(Bool.self, forKey: .retryable)
        memoryChanges = try values.decodeIfPresent([MemoryChange].self, forKey: .memoryChanges) ?? []
        createdAt = try values.decode(String.self, forKey: .createdAt)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
    }
}

struct Conversation: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let principalID: String
    let title: String
    let revision: UInt64
    let messages: [ChatMessage]
    let turns: [ConversationTurn]
    let activeTurnID: String?
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id = "conversation_id", principalID = "principal_id", title, revision, messages, turns
        case activeTurnID = "active_turn_id", createdAt = "created_at", updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        principalID = try values.decode(String.self, forKey: .principalID)
        title = try values.decode(String.self, forKey: .title)
        revision = try values.decode(UInt64.self, forKey: .revision)
        messages = try values.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        turns = try values.decodeIfPresent([ConversationTurn].self, forKey: .turns) ?? []
        activeTurnID = try values.decodeIfPresent(String.self, forKey: .activeTurnID)
        createdAt = try values.decode(String.self, forKey: .createdAt)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
    }
}

struct UserMemory: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: UserMemoryKind
    let text: String
    let status: UserMemoryStatus
    let sensitivity: UserMemorySensitivity
    let origin: String
    let sourceConversationID: String
    let sourceMessageID: String
    let createdAt: String
    let updatedAt: String
    let lastConfirmedAt: String?
    enum CodingKeys: String, CodingKey {
        case id = "memory_id", kind, text, status, sensitivity, origin
        case sourceConversationID = "source_conversation_id", sourceMessageID = "source_message_id"
        case createdAt = "created_at", updatedAt = "updated_at", lastConfirmedAt = "last_confirmed_at"
    }
}

struct MemoryPreferences: Codable, Equatable, Sendable {
    let proactiveEnabled: Bool
    enum CodingKeys: String, CodingKey { case proactiveEnabled = "proactive_enabled" }
}

protocol AgentAnalyzing: Sendable {
    func analyze(question: String, snapshot: AnalysisSnapshot) async throws -> AnalysisResponse
}

protocol AgentConversing: Sendable {
    func capabilities() async throws -> AgentCapabilities
    func listConversations() async throws -> [ConversationSummary]
    func createConversation() async throws -> Conversation
    func getConversation(id: String) async throws -> Conversation
    func deleteConversation(id: String, deleteMemories: Bool) async throws
    func sendMessage(conversationID: String, messageID: String, question: String, periodDays: Int, snapshot: AnalysisSnapshot) async throws -> ConversationTurn
    func resumeTurn(conversationID: String, turnID: String) async throws -> ConversationTurn
    func cancelTurn(conversationID: String, turnID: String) async throws -> ConversationTurn
    func listMemories() async throws -> [UserMemory]
    func confirmMemory(id: String) async throws -> UserMemory
    func rejectMemory(id: String) async throws -> UserMemory
    func deleteMemory(id: String) async throws
    func editMemory(id: String, kind: UserMemoryKind, text: String) async throws -> UserMemory
    func clearMemories() async throws
    func memoryPreferences() async throws -> MemoryPreferences
    func setProactiveMemory(_ enabled: Bool) async throws -> MemoryPreferences
}

enum AgentClientError: LocalizedError, Equatable, Sendable {
    case configuration(String)
    case transport(URLError.Code)
    case invalidResponse
    case server(code: String, message: String, retryable: Bool, runID: String?)

    var errorDescription: String? {
        switch self {
        case .configuration(let message): return message
        case .transport(.timedOut): return "分析超时，请重试。"
        case .transport: return "未连接到当前分析服务，请检查页面显示的地址、网络及服务状态。"
        case .invalidResponse: return "分析服务返回了无法识别的结果，请检查服务版本后重试。"
        case .server(_, let message, _, _): return message
        }
    }
    var retryable: Bool {
        if case .configuration = self { return false }
        if case .server(_, _, let retryable, _) = self { return retryable }
        return true
    }
    var runID: String? {
        if case .server(_, _, _, let runID) = self { return runID }
        return nil
    }
}

struct AgentClient: AgentAnalyzing, AgentConversing {
    static let analysisSession = URLSession(configuration: .ephemeral)
    let session: URLSession
    let baseURL: URL
    let accessToken: String?
    init(session: URLSession = analysisSession, baseURL: URL = URL(string: "http://127.0.0.1:8787")!, accessToken: String? = nil) {
        self.session = session
        self.baseURL = baseURL
        self.accessToken = accessToken
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
        if let accessToken { request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 35
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = try JSONEncoder().encode(Request(question: question, snapshot: snapshot))
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: RejectAnalysisRedirects()) }
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

    func capabilities() async throws -> AgentCapabilities {
        try await getJSON(path: ["v1", "capabilities"], as: AgentCapabilities.self)
    }

    func listConversations() async throws -> [ConversationSummary] {
        struct Result: Decodable { let schemaVersion: Int; let conversations: [ConversationSummary]; enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", conversations } }
        let result = try await getJSON(path: ["v1", "conversations"], as: Result.self)
        guard result.schemaVersion == 1 else { throw AgentClientError.invalidResponse }
        return result.conversations
    }

    func createConversation() async throws -> Conversation {
        try await requestJSON(path: ["v1", "conversations"], method: "POST", body: Data("{}".utf8), expectedStatus: [201], as: Conversation.self)
    }

    func getConversation(id: String) async throws -> Conversation {
        guard !id.isEmpty else { throw AgentClientError.invalidResponse }
        return try await getJSON(path: ["v1", "conversations", id], as: Conversation.self)
    }

    func deleteConversation(id: String, deleteMemories: Bool) async throws {
        var components = URLComponents(url: endpoint(["v1", "conversations", id]), resolvingAgainstBaseURL: false)!
        if deleteMemories { components.queryItems = [URLQueryItem(name: "delete_memories", value: "true")] }
        try await requestEmpty(url: components.url!, method: "DELETE", expectedStatus: [204])
    }

    func sendMessage(conversationID: String, messageID: String, question: String, periodDays: Int, snapshot: AnalysisSnapshot) async throws -> ConversationTurn {
        struct Request: Encodable {
            let schemaVersion = 1
            let messageID: String
            let question: String
            let periodDays: Int
            let snapshot: AnalysisSnapshot
            enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", messageID = "message_id", question, periodDays = "period_days", snapshot }
        }
        let body = try JSONEncoder().encode(Request(messageID: messageID, question: question, periodDays: periodDays, snapshot: snapshot))
        let turn = try await requestJSON(path: ["v1", "conversations", conversationID, "turns"], method: "POST", body: body, expectedStatus: [202], as: ConversationTurn.self)
        try validate(turn: turn)
        if turn.status.isTerminal { return turn }
        return try await pollTurn(conversationID: conversationID, turnID: turn.id)
    }

    func resumeTurn(conversationID: String, turnID: String) async throws -> ConversationTurn {
        try await pollTurn(conversationID: conversationID, turnID: turnID)
    }

    private func pollTurn(conversationID: String, turnID: String) async throws -> ConversationTurn {
        try await withThrowingTaskGroup(of: ConversationTurn.self) { group in
            group.addTask {
                var attempt = 0
                while true {
                    if attempt > 0 {
                        let milliseconds = min(2_000, 200 * (1 << min(attempt - 1, 3)))
                        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                    }
                    try Task.checkCancellation()
                    let turn = try await getJSON(path: ["v1", "conversations", conversationID, "turns", turnID], as: ConversationTurn.self)
                    try validate(turn: turn)
                    if turn.status.isTerminal { return turn }
                    attempt += 1
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                throw AgentClientError.transport(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw AgentClientError.invalidResponse }
            return result
        }
    }

    func cancelTurn(conversationID: String, turnID: String) async throws -> ConversationTurn {
        try await requestJSON(path: ["v1", "conversations", conversationID, "turns", turnID, "cancel"], method: "POST", body: Data("{}".utf8), expectedStatus: [200], as: ConversationTurn.self)
    }

    func listMemories() async throws -> [UserMemory] {
        struct Result: Decodable { let schemaVersion: Int; let memories: [UserMemory]; enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", memories } }
        let result = try await getJSON(path: ["v1", "memories"], as: Result.self)
        guard result.schemaVersion == 1 else { throw AgentClientError.invalidResponse }
        return result.memories
    }

    func confirmMemory(id: String) async throws -> UserMemory {
        try await memoryAction(id: id, action: "confirm")
    }

    func rejectMemory(id: String) async throws -> UserMemory {
        try await memoryAction(id: id, action: "reject")
    }

    func deleteMemory(id: String) async throws {
        try await requestEmpty(url: endpoint(["v1", "memories", id]), method: "DELETE", expectedStatus: [204])
    }

    func editMemory(id: String, kind: UserMemoryKind, text: String) async throws -> UserMemory {
        struct Request: Encodable { let kind: UserMemoryKind; let text: String }
        return try await requestJSON(path: ["v1", "memories", id], method: "PATCH", body: JSONEncoder().encode(Request(kind: kind, text: text)), expectedStatus: [200], as: UserMemory.self)
    }

    func clearMemories() async throws {
        try await requestEmpty(url: endpoint(["v1", "memories"]), method: "DELETE", expectedStatus: [204])
    }

    func memoryPreferences() async throws -> MemoryPreferences {
        try await getJSON(path: ["v1", "memory-settings"], as: MemoryPreferences.self)
    }

    func setProactiveMemory(_ enabled: Bool) async throws -> MemoryPreferences {
        struct Request: Encodable { let proactive_enabled: Bool }
        return try await requestJSON(path: ["v1", "memory-settings"], method: "PUT", body: JSONEncoder().encode(Request(proactive_enabled: enabled)), expectedStatus: [200], as: MemoryPreferences.self)
    }

    private func memoryAction(id: String, action: String) async throws -> UserMemory {
        try await requestJSON(path: ["v1", "memories", id, action], method: "POST", body: Data("{}".utf8), expectedStatus: [200], as: UserMemory.self)
    }

    private func validate(turn: ConversationTurn) throws {
        guard !turn.id.isEmpty, !turn.conversationID.isEmpty, !turn.messageID.isEmpty else { throw AgentClientError.invalidResponse }
        if turn.status == .completed {
            guard let answer = turn.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty,
                  let runID = turn.runID, !runID.isEmpty else { throw AgentClientError.invalidResponse }
        }
    }

    private func getJSON<T: Decodable & Sendable>(path: [String], as type: T.Type) async throws -> T {
        try await requestJSON(path: path, method: "GET", body: nil, expectedStatus: [200], as: type)
    }

    private func requestJSON<T: Decodable & Sendable>(path: [String], method: String, body: Data?, expectedStatus: Set<Int>, as type: T.Type) async throws -> T {
        let (data, response) = try await perform(url: endpoint(path), method: method, body: body)
        guard expectedStatus.contains(response.statusCode) else { throw try decodeServerError(data: data) }
        guard let value = try? JSONDecoder().decode(type, from: data) else { throw AgentClientError.invalidResponse }
        return value
    }

    private func requestEmpty(url: URL, method: String, expectedStatus: Set<Int>) async throws {
        let (data, response) = try await perform(url: url, method: method, body: nil)
        guard expectedStatus.contains(response.statusCode) else { throw try decodeServerError(data: data) }
    }

    private func perform(url: URL, method: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let accessToken { request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 35
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: RejectAnalysisRedirects()) }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AgentClientError.transport(error.code)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, data.count <= 4 * 1024 * 1024 else { throw AgentClientError.invalidResponse }
        return (data, http)
    }

    private func endpoint(_ components: [String]) -> URL {
        components.reduce(baseURL) { $0.appendingPathComponent($1) }
    }

    private func decodeServerError(data: Data) throws -> AgentClientError {
        struct Failure: Decodable {
            struct Detail: Decodable { let code: String; let message: String; let retryable: Bool }
            let schemaVersion: Int
            let runID: String?
            let error: Detail
            enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", runID = "run_id", error }
        }
        guard let failure = try? JSONDecoder().decode(Failure.self, from: data), failure.schemaVersion == 1,
              !failure.error.message.isEmpty else { return .invalidResponse }
        return .server(code: failure.error.code, message: failure.error.message, retryable: failure.error.retryable, runID: failure.runID)
    }
}

/// Never forward a user's analysis payload or credential to a redirect target.
final class RejectAnalysisRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
