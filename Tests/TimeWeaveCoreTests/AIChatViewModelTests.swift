import XCTest
@testable import TimeWeaveCore

@MainActor
final class AIChatViewModelTests: XCTestCase {
    func testChatLoadsLatestConversationAndPersistsSelection() async throws {
        let defaults = isolatedDefaults()
        let latest = try conversation(id: "conv-latest", title: "最近对话")
        let older = try conversation(id: "conv-old", title: "旧对话")
        let client = ChatClientStub(conversations: [latest, older])
        let model = AIChatViewModel(clientProvider: { client }, serviceScope: { "https://agent.example.com" }, defaults: defaults) { try self.snapshot() }

        await model.load()

        XCTAssertEqual(model.mode, .chat)
        XCTAssertEqual(model.currentConversation?.id, "conv-latest")
        XCTAssertEqual(model.conversations.map(\.id), ["conv-latest", "conv-old"])
        let persisted = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }
        XCTAssertTrue(persisted.contains("conv-latest"))

        let second = AIChatViewModel(clientProvider: { client }, serviceScope: { "https://agent.example.com" }, defaults: defaults) { try self.snapshot() }
        await second.load()
        let requestedID = await client.lastRequestedConversationID()
        XCTAssertEqual(requestedID, "conv-latest")
    }

    func testSubmitRebuildsSnapshotAndRetryReusesMessageID() async throws {
        let defaults = isolatedDefaults()
        let base = try conversation(id: "conv-1", title: "对话")
        let completedConversation = try conversation(id: "conv-1", title: "分析", messages: [
            #"{"id":"m1","turn_id":"turn-1","role":"user","text":"分析","created_at":"2026-11-05T01:00:00Z"}"#,
            #"{"id":"m2","turn_id":"turn-1","role":"assistant","text":"工作 60 分钟","created_at":"2026-11-05T01:00:01Z"}"#
        ])
        let completed = try turn(status: "completed", answer: "工作 60 分钟", runID: "run-1")
        let client = ChatClientStub(conversations: [base], sendResults: [
            .failure(AgentClientError.transport(.cannotConnectToHost)),
            .success(completed)
        ], refreshedConversation: completedConversation)
        var snapshots = 0
        let model = AIChatViewModel(clientProvider: { client }, serviceScope: { "local" }, defaults: defaults) {
            snapshots += 1
            return try self.snapshot()
        }
        await model.load()
        model.draft = "分析"

        model.submit()
        await waitUntil { !model.isLoading && model.error != nil }
        model.retry()
        await waitUntil { !model.isLoading && model.messages.count == 2 }

        let ids = await client.submittedMessageIDs()
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], ids[1])
        XCTAssertEqual(snapshots, 2)
        XCTAssertEqual(model.messages.last?.text, "工作 60 分钟")
    }

    func testEnvironmentChangeRejectsStaleResult() async throws {
        let defaults = isolatedDefaults()
        let localConversation = try conversation(id: "local-conv", title: "本地")
        let remoteConversation = try conversation(id: "remote-conv", title: "远端", messages: [
            #"{"id":"remote-answer","turn_id":"remote-turn","role":"assistant","text":"远端新答案","created_at":"2026-11-05T01:00:01Z"}"#
        ])
        let delayed = DelayedChatClient(conversation: localConversation)
        let remote = ChatClientStub(conversations: [remoteConversation], sendResults: [.success(try turn(status: "completed", answer: "远端新答案", runID: "remote-run"))], refreshedConversation: remoteConversation)
        let selection = ChatSelection(client: delayed, scope: "local")
        let model = AIChatViewModel(clientProvider: { selection.client }, serviceScope: { selection.scope }, defaults: defaults) { try self.snapshot() }
        await model.load()
        model.draft = "旧问题"
        model.submit()
        await delayed.waitForSubmission()

        selection.client = remote
        selection.scope = "remote"
        model.serviceConfigurationChanged()
        await waitUntil { model.currentConversation?.id == "remote-conv" }
        model.draft = "新问题"
        model.submit()
        await waitUntil { !model.isLoading && model.messages.last?.text == "远端新答案" }
        await delayed.finish(with: try turn(status: "completed", answer: "本地旧答案", runID: "local-run"))
        await settle()

        XCTAssertEqual(model.currentConversation?.id, "remote-conv")
        XCTAssertEqual(model.messages.last?.text, "远端新答案")
    }

    func testOldServerFallsBackToLegacyAnalysis() async throws {
        let client = ChatClientStub(capabilitiesError: AgentClientError.server(code: "not_found", message: "接口不存在", retryable: false, runID: nil), legacyAnswer: "旧接口答案")
        let model = AIChatViewModel(clientProvider: { client }, serviceScope: { "old" }, defaults: isolatedDefaults()) { try self.snapshot() }

        await model.load()
        XCTAssertEqual(model.mode, .legacy)
        model.draft = "分析"
        model.submit()
        await waitUntil { !model.isLoading && model.messages.count == 2 }

        XCTAssertEqual(model.messages.last?.text, "旧接口答案")
    }

    func testMemoryActionsUpdateAfterServerSuccess() async throws {
        let proposed = try memory(id: "memory-1", status: "proposed")
        let active = try memory(id: "memory-1", status: "active")
        let client = ChatClientStub(conversations: [try conversation(id: "conv-1", title: "对话")], memories: [proposed], confirmedMemory: active)
        let model = AIChatViewModel(clientProvider: { client }, serviceScope: { "local" }, defaults: isolatedDefaults()) { try self.snapshot() }
        await model.load()
        XCTAssertEqual(model.memories.first?.status, .proposed)

        await model.confirmMemory(id: "memory-1")
        XCTAssertEqual(model.memories.first?.status, .active)
        await model.deleteMemory(id: "memory-1")
        XCTAssertTrue(model.memories.isEmpty)
    }

    private func snapshot() throws -> AnalysisSnapshot {
        try AnalysisSnapshotBuilder.build(ledger: TimeLedger(), period: 7)
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "AIChatViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func conversation(id: String, title: String, messages: [String] = []) throws -> Conversation {
        let messageJSON = "[" + messages.joined(separator: ",") + "]"
        return try JSONDecoder().decode(Conversation.self, from: Data(#"{"conversation_id":"\#(id)","principal_id":"local","title":"\#(title)","revision":1,"messages":\#(messageJSON),"turns":[],"created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:00Z"}"#.utf8))
    }

    private func turn(status: String, answer: String?, runID: String?) throws -> ConversationTurn {
        let answerJSON = answer.map { #", "answer":"\#($0)""# } ?? ""
        let runJSON = runID.map { #", "run_id":"\#($0)""# } ?? ""
        let json = #"{"turn_id":"turn-1","conversation_id":"conv-1","message_id":"client-1","thread_id":"thread-1","question":"分析","period_days":7,"status":"\#(status)"\#(runJSON)\#(answerJSON),"memory_changes":[],"created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:01Z"}"#
        return try JSONDecoder().decode(ConversationTurn.self, from: Data(json.utf8))
    }

    private func memory(id: String, status: String) throws -> UserMemory {
        try JSONDecoder().decode(UserMemory.self, from: Data(#"{"memory_id":"\#(id)","kind":"goal","text":"减少晚间工作","status":"\#(status)","sensitivity":"normal","origin":"explicit_user","source_conversation_id":"conv-1","source_message_id":"client-1","created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:00Z"}"#.utf8))
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("condition was not reached")
    }

    private func settle() async { for _ in 0..<50 { await Task.yield() } }
}

@MainActor
private final class ChatSelection {
    var client: any AIChatService
    var scope: String
    init(client: any AIChatService, scope: String) { self.client = client; self.scope = scope }
}

private actor ChatClientStub: AIChatService {
    private let capabilitiesError: Error?
    private var conversations: [Conversation]
    private var sendResults: [Result<ConversationTurn, Error>]
    private let refreshedConversation: Conversation?
    private var memories: [UserMemory]
    private let confirmedMemory: UserMemory?
    private let legacyAnswer: String
    private var messageIDs: [String] = []
    private var requestedConversationID: String?

    init(conversations: [Conversation] = [], sendResults: [Result<ConversationTurn, Error>] = [], refreshedConversation: Conversation? = nil,
         memories: [UserMemory] = [], confirmedMemory: UserMemory? = nil, capabilitiesError: Error? = nil, legacyAnswer: String = "legacy") {
        self.conversations = conversations
        self.sendResults = sendResults
        self.refreshedConversation = refreshedConversation
        self.memories = memories
        self.confirmedMemory = confirmedMemory
        self.capabilitiesError = capabilitiesError
        self.legacyAnswer = legacyAnswer
    }

    func capabilities() async throws -> AgentCapabilities {
        if let capabilitiesError { throw capabilitiesError }
        return AgentCapabilities(schemaVersion: 1, conversations: true, memories: true)
    }
    func listConversations() async throws -> [ConversationSummary] {
        conversations.map { ConversationSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
    }
    func createConversation() async throws -> Conversation { conversations[0] }
    func getConversation(id: String) async throws -> Conversation {
        requestedConversationID = id
        if let refreshedConversation, id == refreshedConversation.id { return refreshedConversation }
        return conversations.first { $0.id == id }!
    }
    func deleteConversation(id: String, deleteMemories: Bool) async throws { conversations.removeAll { $0.id == id } }
    func sendMessage(conversationID: String, messageID: String, question: String, periodDays: Int, snapshot: AnalysisSnapshot) async throws -> ConversationTurn {
        messageIDs.append(messageID)
        return try sendResults.removeFirst().get()
    }
    func cancelTurn(conversationID: String, turnID: String) async throws -> ConversationTurn { try sendResults[0].get() }
    func listMemories() async throws -> [UserMemory] { memories }
    func confirmMemory(id: String) async throws -> UserMemory {
        let value = confirmedMemory!
        memories = [value]
        return value
    }
    func rejectMemory(id: String) async throws -> UserMemory { memories[0] }
    func deleteMemory(id: String) async throws { memories.removeAll { $0.id == id } }
    func analyze(question: String, snapshot: AnalysisSnapshot) async throws -> AnalysisResponse {
        AnalysisResponse(schemaVersion: 1, runID: "legacy-run", answer: legacyAnswer)
    }
    func submittedMessageIDs() -> [String] { messageIDs }
    func lastRequestedConversationID() -> String? { requestedConversationID }
}

private actor DelayedChatClient: AIChatService {
    private let conversation: Conversation
    private var continuation: CheckedContinuation<ConversationTurn, Error>?
    private var submitted = false
    init(conversation: Conversation) { self.conversation = conversation }
    func capabilities() async throws -> AgentCapabilities { AgentCapabilities(schemaVersion: 1, conversations: true, memories: true) }
    func listConversations() async throws -> [ConversationSummary] { [ConversationSummary(id: conversation.id, title: conversation.title, updatedAt: conversation.updatedAt)] }
    func createConversation() async throws -> Conversation { conversation }
    func getConversation(id: String) async throws -> Conversation { conversation }
    func deleteConversation(id: String, deleteMemories: Bool) async throws {}
    func sendMessage(conversationID: String, messageID: String, question: String, periodDays: Int, snapshot: AnalysisSnapshot) async throws -> ConversationTurn {
        submitted = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func cancelTurn(conversationID: String, turnID: String) async throws -> ConversationTurn { fatalError() }
    func listMemories() async throws -> [UserMemory] { [] }
    func confirmMemory(id: String) async throws -> UserMemory { fatalError() }
    func rejectMemory(id: String) async throws -> UserMemory { fatalError() }
    func deleteMemory(id: String) async throws {}
    func analyze(question: String, snapshot: AnalysisSnapshot) async throws -> AnalysisResponse { fatalError() }
    func waitForSubmission() async { for _ in 0..<1_000 { if submitted { return }; await Task.yield() } }
    func finish(with turn: ConversationTurn) { continuation?.resume(returning: turn); continuation = nil }
}

