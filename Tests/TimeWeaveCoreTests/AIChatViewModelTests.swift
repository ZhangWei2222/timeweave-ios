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
        let client = ChatClientStub(conversations: [base], sendResults: [
            .failure(AgentClientError.transport(.cannotConnectToHost)),
            .success(receipt())
        ], refreshedConversation: completedConversation)
        var snapshots = 0
        let model = AIChatViewModel(clientProvider: { client }, serviceScope: { "local" }, defaults: defaults) {
            snapshots += 1
            return try self.snapshot()
        }
        await model.load()
        model.draft = "分析"

        model.submit()
        await waitUntil { !model.isSubmitting && model.error != nil }
        model.retry()
        await waitUntil { !model.isSubmitting && model.messages.count == 2 }

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
        let remote = ChatClientStub(conversations: [remoteConversation], sendResults: [.success(receipt())], refreshedConversation: remoteConversation)
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
        await waitUntil { !model.isSubmitting && model.messages.last?.text == "远端新答案" }
        await delayed.finish(with: receipt())
        await settle()

        XCTAssertEqual(model.currentConversation?.id, "remote-conv")
        XCTAssertEqual(model.messages.last?.text, "远端新答案")
    }

    func testSelectingAnotherConversationRejectsOldTurnResult() async throws {
        let first = try conversation(id: "conv-a", title: "A")
        let second = try conversation(id: "conv-b", title: "B", messages: [
            #"{"id":"b1","turn_id":"turn-b","role":"assistant","text":"B 的内容","created_at":"2026-11-05T01:00:00Z"}"#
        ])
        let client = SwitchingChatClient(conversations: [first, second])
        let model = AIChatViewModel(clientProvider: { client }, serviceScope: { "local" }, defaults: isolatedDefaults()) { try self.snapshot() }
        await model.load()
        model.draft = "A 的问题"
        model.submit()
        await client.waitForSubmission()

        await model.selectConversation(id: second.id)
        await client.finish(with: receipt())
        await settle()

        XCTAssertEqual(model.currentConversation?.id, second.id)
        XCTAssertEqual(model.messages.last?.text, "B 的内容")
    }

    func testNewDraftSurvivesDelayedReceipt() async throws {
        let client = DelayedChatClient(conversation: try conversation(id: "conv-1", title: "分析"))
        let model = AIChatViewModel(clientProvider: { client }, serviceScope: { "local" }, defaults: isolatedDefaults()) { try self.snapshot() }
        await model.load()
        model.draft = "B"
        model.submit()
        await client.waitForSubmission()

        model.draft = "C"
        await client.finish(with: receipt())
        await waitUntil { !model.isSubmitting }

        XCTAssertEqual(model.draft, "C")
        XCTAssertTrue(model.canSubmit)
    }

    func testQueuedTurnsStaySendableAndHandoffAfterSteering() async throws {
        let a = try turn(status: "running", id: "a")
        let b = try turn(status: "queued", id: "b")
        let c = try turn(status: "queued", id: "c")
        let steeredB = try turn(status: "steered", id: "b", targetTurnID: "a")
        let completedA = try turn(status: "completed", answer: "A 和 B 的答案", runID: "run-a", id: "a")
        let runningC = try turn(status: "running", id: "c")
        let completedC = try turn(status: "completed", answer: "C 的答案", runID: "run-c", id: "c")
        let initial = try conversation(id: "conv-1", title: "分析", turns: [a], activeTurnID: "a")
        let client = ChatClientStub(conversations: [initial], sendResults: [
            .success(receipt(turnID: "b", disposition: .queued, revision: 2)),
            .success(receipt(turnID: "c", disposition: .queued, revision: 3))
        ])
        let model = AIChatViewModel(clientProvider: { client }, serviceScope: { "local" }, defaults: isolatedDefaults()) { try self.snapshot() }

        await model.load()
        XCTAssertTrue(model.isObserving)
        model.draft = "B"
        XCTAssertTrue(model.canSubmit)
        await client.holdNextRefresh()
        model.submit()
        await waitUntil { !model.isSubmitting }
        await client.waitForHeldRefresh()

        await client.setRefreshedConversation(try conversation(id: "conv-1", title: "分析", turns: [a, b, c], activeTurnID: "a", revision: 3))
        model.draft = "C"
        model.submit()
        await waitUntil { model.queuedTurns.map(\.id) == ["b", "c"] }

        await client.setRefreshedConversation(try conversation(id: "conv-1", title: "分析", turns: [a, steeredB, c], activeTurnID: "a", revision: 4))
        await model.steer(b)
        let steeredTarget = await client.steeredTarget
        XCTAssertEqual(steeredTarget, "a")
        XCTAssertEqual(model.queuedTurns.map(\.id), ["c"])
        XCTAssertEqual(model.currentConversation?.turns[1].targetTurnID, "a")

        await client.releaseRefresh(with: try conversation(id: "conv-1", title: "分析", turns: [a, b], activeTurnID: "a", revision: 2))
        await settle()
        XCTAssertEqual(model.currentConversation?.revision, 4)
        XCTAssertEqual(model.queuedTurns.map(\.id), ["c"])

        model.draft = "D"
        await client.setRefreshedConversation(try conversation(id: "conv-1", title: "分析", turns: [completedA, steeredB, c], revision: 5))
        await client.finishObservation(with: completedA)
        await waitUntil { model.currentConversation?.revision == 5 }
        XCTAssertTrue(model.isObserving)

        await client.setRefreshedConversation(try conversation(id: "conv-1", title: "分析", turns: [completedA, steeredB, runningC], activeTurnID: "c", revision: 6))
        await waitUntil { model.currentConversation?.activeTurnID == "c" }
        await client.setRefreshedConversation(try conversation(id: "conv-1", title: "分析", turns: [completedA, steeredB, completedC], revision: 7))
        await client.finishObservation(with: completedC)
        await waitUntil { !model.isObserving }

        let observedIDs = await client.resumedTurnIDs()
        XCTAssertEqual(observedIDs, ["a", "c"])
        XCTAssertEqual(model.currentConversation?.revision, 7)
        XCTAssertTrue(model.queuedTurns.isEmpty)
        XCTAssertEqual(model.draft, "D")
    }

    func testLoadResumesServerActiveTurnAfterViewModelRecreation() async throws {
        let running = try turn(status: "running", answer: nil, runID: "run-active")
        let active = try conversation(id: "conv-1", title: "分析", turns: [running], activeTurnID: running.id)
        let completedConversation = try conversation(id: "conv-1", title: "分析", messages: [
            #"{"id":"m1","turn_id":"turn-1","role":"user","text":"分析","created_at":"2026-11-05T01:00:00Z"}"#,
            #"{"id":"m2","turn_id":"turn-1","role":"assistant","text":"恢复后的答案","created_at":"2026-11-05T01:00:01Z"}"#
        ])
        let completed = try turn(status: "completed", answer: "恢复后的答案", runID: "run-active")
        let client = ChatClientStub(conversations: [active], refreshedConversation: completedConversation, resumeResults: [.success(completed)])
        let model = AIChatViewModel(clientProvider: { client }, serviceScope: { "local" }, defaults: isolatedDefaults()) { try self.snapshot() }

        await model.load()
        await waitUntil { !model.isObserving && model.messages.last?.text == "恢复后的答案" }

        let resumedIDs = await client.resumedTurnIDs()
        XCTAssertEqual(resumedIDs, [running.id])
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
        await model.editMemory(id: "memory-1", kind: .goal, text: "每周减少晚间工作")
        XCTAssertEqual(model.memories.first?.text, "每周减少晚间工作")
        await model.setProactiveMemory(false)
        XCTAssertFalse(model.memoryPreferences.proactiveEnabled)
        await model.clearMemories()
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

    private func conversation(id: String, title: String, messages: [String] = [], turns: [ConversationTurn] = [], activeTurnID: String? = nil, revision: UInt64 = 1) throws -> Conversation {
        let messageJSON = "[" + messages.joined(separator: ",") + "]"
        let turnData = try JSONEncoder().encode(turns)
        let turnJSON = String(decoding: turnData, as: UTF8.self)
        let activeJSON = activeTurnID.map { #", "active_turn_id":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(Conversation.self, from: Data(#"{"conversation_id":"\#(id)","principal_id":"local","title":"\#(title)","revision":\#(revision),"messages":\#(messageJSON),"turns":\#(turnJSON)\#(activeJSON),"created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:00Z"}"#.utf8))
    }

    private func turn(status: String, answer: String? = nil, runID: String? = nil, id: String = "turn-1", targetTurnID: String? = nil) throws -> ConversationTurn {
        let answerJSON = answer.map { #", "answer":"\#($0)""# } ?? ""
        let runJSON = runID.map { #", "run_id":"\#($0)""# } ?? ""
        let targetJSON = targetTurnID.map { #", "target_turn_id":"\#($0)""# } ?? ""
        let json = #"{"turn_id":"\#(id)","conversation_id":"conv-1","message_id":"message-\#(id)","thread_id":"thread-1","question":"分析","period_days":7,"status":"\#(status)"\#(runJSON)\#(answerJSON)\#(targetJSON),"memory_changes":[],"created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:01Z"}"#
        return try JSONDecoder().decode(ConversationTurn.self, from: Data(json.utf8))
    }

    private func memory(id: String, status: String) throws -> UserMemory {
        try JSONDecoder().decode(UserMemory.self, from: Data(#"{"memory_id":"\#(id)","kind":"goal","text":"减少晚间工作","status":"\#(status)","sensitivity":"normal","origin":"explicit_user","source_conversation_id":"conv-1","source_message_id":"client-1","created_at":"2026-11-05T01:00:00Z","updated_at":"2026-11-05T01:00:00Z"}"#.utf8))
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition was not reached")
    }

    private func settle() async { for _ in 0..<50 { await Task.yield() } }
}

private func receipt(turnID: String = "turn-1", disposition: ConversationInputReceipt.Disposition = .started, revision: UInt64 = 1) -> ConversationInputReceipt {
    ConversationInputReceipt(schemaVersion: 1, messageID: "message-" + turnID, disposition: disposition, turnID: turnID, conversationRevision: revision)
}

@MainActor
private final class ChatSelection {
    var client: any AgentConversing
    var scope: String
    init(client: any AgentConversing, scope: String) { self.client = client; self.scope = scope }
}

private actor ChatClientStub: AgentConversing {
    private let fixedCapabilities: AgentCapabilities
    private var conversations: [Conversation]
    private var sendResults: [Result<ConversationInputReceipt, Error>]
    private var refreshedConversation: Conversation?
    private var memories: [UserMemory]
    private let confirmedMemory: UserMemory?
    private var messageIDs: [String] = []
    private var requestedConversationID: String?
    private var resumeResults: [Result<ConversationTurn, Error>]
    private var resumedIDs: [String] = []
    private var shouldHoldRefresh = false
    private var heldRefresh: CheckedContinuation<Conversation, Never>?
    private var observations: [String: CheckedContinuation<ConversationTurn, Never>] = [:]
    private(set) var steeredTarget: String?
    private var submitted = false

    init(conversations: [Conversation] = [], sendResults: [Result<ConversationInputReceipt, Error>] = [], refreshedConversation: Conversation? = nil,
         resumeResults: [Result<ConversationTurn, Error>] = [], memories: [UserMemory] = [], confirmedMemory: UserMemory? = nil,
         capabilities: AgentCapabilities = AgentCapabilities(schemaVersion: 1, conversations: true, memories: true)) {
        self.conversations = conversations
        self.sendResults = sendResults
        self.refreshedConversation = refreshedConversation
        self.memories = memories
        self.confirmedMemory = confirmedMemory
        self.fixedCapabilities = capabilities
        self.resumeResults = resumeResults
    }

    func capabilities() async throws -> AgentCapabilities {
        return fixedCapabilities
    }
    func listConversations() async throws -> [ConversationSummary] {
        conversations.map { ConversationSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
    }
    func createConversation() async throws -> Conversation { conversations[0] }
    func getConversation(id: String) async throws -> Conversation {
        if shouldHoldRefresh {
            shouldHoldRefresh = false
            return await withCheckedContinuation { heldRefresh = $0 }
        }
        requestedConversationID = id
        if let refreshedConversation, id == refreshedConversation.id, submitted || !resumedIDs.isEmpty { return refreshedConversation }
        return conversations.first { $0.id == id }!
    }
    func deleteConversation(id: String, deleteMemories: Bool) async throws { conversations.removeAll { $0.id == id } }
    func submitMessage(conversationID: String, messageID: String, question: String, periodDays: Int, snapshot: AnalysisSnapshot) async throws -> ConversationInputReceipt {
        messageIDs.append(messageID)
        submitted = true
        return try sendResults.removeFirst().get()
    }
    func steerQueuedTurn(conversationID: String, messageID: String, expectedTurnID: String) async throws -> ConversationInputReceipt {
        steeredTarget = expectedTurnID
        return receipt(turnID: "b", disposition: .steered, revision: 4)
    }
    func cancelTurn(conversationID: String, turnID: String) async throws -> ConversationTurn { fatalError() }
    func observeTurn(conversationID: String, turnID: String) async throws -> ConversationTurn {
        resumedIDs.append(turnID)
        if !resumeResults.isEmpty { return try resumeResults.removeFirst().get() }
        return await withCheckedContinuation { observations[turnID] = $0 }
    }
    func finishObservation(with turn: ConversationTurn) async {
        for _ in 0..<200 {
            if let continuation = observations.removeValue(forKey: turn.id) {
                continuation.resume(returning: turn)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("turn was not observed: \(turn.id)")
    }
    func holdNextRefresh() { shouldHoldRefresh = true }
    func waitForHeldRefresh() async {
        for _ in 0..<200 {
            if heldRefresh != nil { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("refresh was not held")
    }
    func releaseRefresh(with conversation: Conversation) {
        heldRefresh?.resume(returning: conversation)
        heldRefresh = nil
    }
    func setRefreshedConversation(_ conversation: Conversation) { refreshedConversation = conversation }
    func listMemories() async throws -> [UserMemory] { memories }
    func confirmMemory(id: String) async throws -> UserMemory {
        let value = confirmedMemory!
        memories = [value]
        return value
    }
    func rejectMemory(id: String) async throws -> UserMemory { memories[0] }
    func deleteMemory(id: String) async throws { memories.removeAll { $0.id == id } }
    func editMemory(id: String, kind: UserMemoryKind, text: String) async throws -> UserMemory {
        let current = memories.first!
        let data = try JSONEncoder().encode(current)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["kind"] = kind.rawValue; object["text"] = text
        let edited = try JSONDecoder().decode(UserMemory.self, from: JSONSerialization.data(withJSONObject: object))
        memories = [edited]; return edited
    }
    func clearMemories() async throws { memories = [] }
    func memoryPreferences() async throws -> MemoryPreferences { MemoryPreferences(proactiveEnabled: true) }
    func setProactiveMemory(_ enabled: Bool) async throws -> MemoryPreferences { MemoryPreferences(proactiveEnabled: enabled) }
    func submittedMessageIDs() -> [String] { messageIDs }
    func lastRequestedConversationID() -> String? { requestedConversationID }
    func resumedTurnIDs() -> [String] { resumedIDs }
}

private actor DelayedChatClient: AgentConversing {
    private let conversation: Conversation
    private var continuation: CheckedContinuation<ConversationInputReceipt, Error>?
    private var submitted = false
    init(conversation: Conversation) { self.conversation = conversation }
    func capabilities() async throws -> AgentCapabilities { AgentCapabilities(schemaVersion: 1, conversations: true, memories: true) }
    func listConversations() async throws -> [ConversationSummary] { [ConversationSummary(id: conversation.id, title: conversation.title, updatedAt: conversation.updatedAt)] }
    func createConversation() async throws -> Conversation { conversation }
    func getConversation(id: String) async throws -> Conversation { conversation }
    func deleteConversation(id: String, deleteMemories: Bool) async throws {}
    func submitMessage(conversationID: String, messageID: String, question: String, periodDays: Int, snapshot: AnalysisSnapshot) async throws -> ConversationInputReceipt {
        submitted = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func steerQueuedTurn(conversationID: String, messageID: String, expectedTurnID: String) async throws -> ConversationInputReceipt { fatalError() }
    func cancelTurn(conversationID: String, turnID: String) async throws -> ConversationTurn { fatalError() }
    func observeTurn(conversationID: String, turnID: String) async throws -> ConversationTurn { fatalError() }
    func listMemories() async throws -> [UserMemory] { [] }
    func confirmMemory(id: String) async throws -> UserMemory { fatalError() }
    func rejectMemory(id: String) async throws -> UserMemory { fatalError() }
    func deleteMemory(id: String) async throws {}
    func editMemory(id: String, kind: UserMemoryKind, text: String) async throws -> UserMemory { fatalError() }
    func clearMemories() async throws {}
    func memoryPreferences() async throws -> MemoryPreferences { MemoryPreferences(proactiveEnabled: true) }
    func setProactiveMemory(_ enabled: Bool) async throws -> MemoryPreferences { MemoryPreferences(proactiveEnabled: enabled) }
    func waitForSubmission() async { for _ in 0..<1_000 { if submitted { return }; await Task.yield() } }
    func finish(with receipt: ConversationInputReceipt) { continuation?.resume(returning: receipt); continuation = nil }
}

private actor SwitchingChatClient: AgentConversing {
    private let conversations: [Conversation]
    private var continuation: CheckedContinuation<ConversationInputReceipt, Error>?
    private var submitted = false
    init(conversations: [Conversation]) { self.conversations = conversations }
    func capabilities() async throws -> AgentCapabilities { AgentCapabilities(schemaVersion: 1, conversations: true, memories: true) }
    func listConversations() async throws -> [ConversationSummary] { conversations.map { ConversationSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) } }
    func createConversation() async throws -> Conversation { conversations[0] }
    func getConversation(id: String) async throws -> Conversation { conversations.first { $0.id == id }! }
    func deleteConversation(id: String, deleteMemories: Bool) async throws {}
    func submitMessage(conversationID: String, messageID: String, question: String, periodDays: Int, snapshot: AnalysisSnapshot) async throws -> ConversationInputReceipt {
        submitted = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func observeTurn(conversationID: String, turnID: String) async throws -> ConversationTurn { fatalError() }
    func steerQueuedTurn(conversationID: String, messageID: String, expectedTurnID: String) async throws -> ConversationInputReceipt { fatalError() }
    func cancelTurn(conversationID: String, turnID: String) async throws -> ConversationTurn { fatalError() }
    func listMemories() async throws -> [UserMemory] { [] }
    func confirmMemory(id: String) async throws -> UserMemory { fatalError() }
    func rejectMemory(id: String) async throws -> UserMemory { fatalError() }
    func deleteMemory(id: String) async throws {}
    func editMemory(id: String, kind: UserMemoryKind, text: String) async throws -> UserMemory { fatalError() }
    func clearMemories() async throws {}
    func memoryPreferences() async throws -> MemoryPreferences { MemoryPreferences(proactiveEnabled: true) }
    func setProactiveMemory(_ enabled: Bool) async throws -> MemoryPreferences { MemoryPreferences(proactiveEnabled: enabled) }
    func waitForSubmission() async { for _ in 0..<1_000 { if submitted { return }; await Task.yield() } }
    func finish(with receipt: ConversationInputReceipt) { continuation?.resume(returning: receipt); continuation = nil }
}

