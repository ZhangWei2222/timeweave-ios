import Foundation
import Combine

@MainActor
final class AIAnalysisViewModel: ObservableObject {
    @Published var question = "分析这段时间的分配，指出最值得先关注的一点。"
    @Published private(set) var isLoading = false
    @Published private(set) var response: AnalysisResponse?
    @Published private(set) var error: AgentClientError?
    private let clientProvider: @MainActor () throws -> any AgentAnalyzing
    private let snapshotBuilder: @MainActor () throws -> AnalysisSnapshot
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(client: any AgentAnalyzing = AgentClient(), snapshotBuilder: @escaping @MainActor () throws -> AnalysisSnapshot) {
        self.clientProvider = { client }
        self.snapshotBuilder = snapshotBuilder
    }
    init(clientProvider: @escaping @MainActor () throws -> any AgentAnalyzing, snapshotBuilder: @escaping @MainActor () throws -> AnalysisSnapshot) {
        self.clientProvider = clientProvider
        self.snapshotBuilder = snapshotBuilder
    }
    var canSubmit: Bool {
        let count = question.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
        return !isLoading && (1...500).contains(count)
    }
    func submit() {
        guard canSubmit else { return }
        let client: any AgentAnalyzing
        do { client = try clientProvider() }
        catch {
            response = nil
            self.error = (error as? AgentClientError) ?? .configuration("服务配置不可用，请检查服务设置。")
            return
        }
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
    func serviceConfigurationChanged() {
        cancel()
        response = nil
        error = nil
    }
}

enum AIChatMode: Equatable, Sendable {
    case loading
    case chat
}

@MainActor
final class AIChatViewModel: ObservableObject {
    @Published var draft = "分析这段时间的分配，指出最值得先关注的一点。" {
        didSet { if draft != oldValue { draftRevision &+= 1 } }
    }
    @Published private(set) var mode: AIChatMode = .loading
    @Published private(set) var conversations: [ConversationSummary] = []
    @Published private(set) var currentConversation: Conversation?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var memories: [UserMemory] = []
    @Published private(set) var memoryPreferences = MemoryPreferences(proactiveEnabled: true)
    @Published private(set) var isObserving = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var steeringTurnIDs: Set<String> = []
    @Published private(set) var supportsMemories = false
    @Published private var isSwitchingConversation = false
    @Published private(set) var error: AgentClientError?

    private struct PendingSubmission {
        let question: String
        let messageID: String
    }

    private let clientProvider: @MainActor () throws -> any AgentConversing
    private let serviceScope: @MainActor () -> String
    private let defaults: UserDefaults
    private let snapshotBuilder: @MainActor () throws -> AnalysisSnapshot
    private var pendingSubmission: PendingSubmission?
    private var submissionTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var draftRevision: UInt64 = 0
    private var minimumRevision: UInt64 = 0
    private var generation = UUID()

    init(clientProvider: @escaping @MainActor () throws -> any AgentConversing,
         serviceScope: @escaping @MainActor () -> String,
         defaults: UserDefaults = .standard,
         snapshotBuilder: @escaping @MainActor () throws -> AnalysisSnapshot) {
        self.clientProvider = clientProvider
        self.serviceScope = serviceScope
        self.defaults = defaults
        self.snapshotBuilder = snapshotBuilder
    }

    var canSubmit: Bool {
        let count = draft.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
        return !isSubmitting && !isSwitchingConversation && mode == .chat && currentConversation != nil && (1...500).contains(count)
    }

    var queuedTurns: [ConversationTurn] {
        currentConversation?.turns.filter { $0.status == .queued } ?? []
    }

    var canSteer: Bool {
        !isSwitchingConversation && currentConversation?.activeTurnID != nil
    }

    var blockedTurn: ConversationTurn? {
        guard let conversation = currentConversation, let id = conversation.queueBlockedByTurnID else { return nil }
        return conversation.turns.first { $0.id == id }
    }

    var blockedTurnError: AgentClientError? {
        blockedTurn.map {
            .server(code: $0.errorCode ?? $0.status.rawValue, message: $0.errorMessage ?? "分析暂时中断。", retryable: $0.retryable ?? false, runID: $0.runID)
        }
    }

    func load() async {
        let expectedGeneration = generation
        do {
            let client = try clientProvider()
            let capabilities = try await client.capabilities()
            guard capabilities.schemaVersion == 1 else { throw AgentClientError.invalidResponse }
            guard capabilities.conversations else {
                throw AgentClientError.configuration("当前服务未启用对话。")
            }
            let summaries = try await client.listConversations()
            guard generation == expectedGeneration, !Task.isCancelled else { return }
            let selected: Conversation
            if let selectedID = selectedConversationID(from: summaries) {
                selected = try await client.getConversation(id: selectedID)
            } else {
                selected = try await client.createConversation()
            }
            let loadedMemories = capabilities.memories ? try await client.listMemories() : []
            let loadedPreferences = capabilities.memories ? try await client.memoryPreferences() : MemoryPreferences(proactiveEnabled: false)
            guard generation == expectedGeneration, !Task.isCancelled else { return }
            mode = .chat
            conversations = summaries
            supportsMemories = capabilities.memories
            memories = loadedMemories
            memoryPreferences = loadedPreferences
            error = nil
            activateConversation(selected, client: client)
        } catch {
            guard generation == expectedGeneration, !Task.isCancelled else { return }
            mode = .loading
            self.error = normalized(error)
        }
    }

    func submit() {
        guard canSubmit else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let submission = pendingSubmission.flatMap { $0.question == question ? $0 : nil }
            ?? PendingSubmission(question: question, messageID: UUID().uuidString.lowercased())
        submit(submission, clearingDraftAt: draftRevision)
    }

    private func submit(_ submission: PendingSubmission, clearingDraftAt submittedDraftRevision: UInt64?) {
        guard let conversationID = currentConversation?.id else { return }
        let client: any AgentConversing
        do { client = try clientProvider() }
        catch { self.error = normalized(error); return }
        let snapshot: AnalysisSnapshot
        do { snapshot = try snapshotBuilder() }
        catch {
            self.error = .server(code: "snapshot_invalid", message: "无法生成统计快照，请检查本地记录。", retryable: false, runID: nil)
            return
        }

        pendingSubmission = submission
        let expectedGeneration = generation
        isSubmitting = true
        error = nil
        submissionTask = Task { [weak self, client] in
            guard let self else { return }
            do {
                let receipt = try await client.submitMessage(conversationID: conversationID, messageID: submission.messageID,
                                                            question: submission.question, periodDays: snapshot.days.count, snapshot: snapshot)
                guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                self.minimumRevision = max(self.minimumRevision, receipt.conversationRevision)
                self.pendingSubmission = nil
                if self.draftRevision == submittedDraftRevision { self.draft = "" }
                self.finishSubmitting()
                await self.refreshAndObserve(client: client, conversationID: conversationID, expectedGeneration: expectedGeneration)
            } catch {
                guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                self.error = self.normalized(error)
                self.finishSubmitting()
            }
        }
    }

    func steer(_ turn: ConversationTurn) async {
        guard canSteer, let conversation = currentConversation, let activeTurnID = conversation.activeTurnID,
              queuedTurns.contains(where: { $0.id == turn.id }), steeringTurnIDs.insert(turn.id).inserted else { return }
        let expectedGeneration = generation
        defer { if generation == expectedGeneration { steeringTurnIDs.remove(turn.id) } }
        let client: any AgentConversing
        do { client = try clientProvider() }
        catch { self.error = normalized(error); return }
        error = nil
        do {
            let receipt = try await client.steerQueuedTurn(conversationID: conversation.id, messageID: turn.messageID, expectedTurnID: activeTurnID)
            guard generation == expectedGeneration, !Task.isCancelled else { return }
            minimumRevision = max(minimumRevision, receipt.conversationRevision)
        } catch {
            guard generation == expectedGeneration, !Task.isCancelled else { return }
            self.error = normalized(error)
        }
        await refreshAndObserve(client: client, conversationID: conversation.id, expectedGeneration: expectedGeneration)
    }

    func retry() {
        guard !isSubmitting, !isSwitchingConversation, let conversationID = currentConversation?.id else { return }
        if let pendingSubmission, error != nil {
            let currentQuestion = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            submit(pendingSubmission, clearingDraftAt: currentQuestion == pendingSubmission.question ? draftRevision : nil)
            return
        }
        if let blockedTurn, blockedTurn.status == .paused, blockedTurn.retryable == true {
            submit(PendingSubmission(question: blockedTurn.question, messageID: blockedTurn.messageID), clearingDraftAt: nil)
            return
        }
        let expectedGeneration = generation
        do {
            let client = try clientProvider()
            error = nil
            Task { await refreshAndObserve(client: client, conversationID: conversationID, expectedGeneration: expectedGeneration) }
        } catch { self.error = normalized(error) }
    }

    func cancelPolling() {
        generation = UUID()
        submissionTask?.cancel()
        finishSubmitting()
        observationTask?.cancel()
        observationTask = nil
        isObserving = false
        loadTask?.cancel()
        loadTask = nil
        isSwitchingConversation = false
        steeringTurnIDs.removeAll()
    }

    func serviceConfigurationChanged() {
        cancelPolling()
        pendingSubmission = nil
        minimumRevision = 0
        mode = .loading
        conversations = []
        currentConversation = nil
        messages = []
        memories = []
        supportsMemories = false
        memoryPreferences = MemoryPreferences(proactiveEnabled: true)
        error = nil
        loadTask = Task { [weak self] in await self?.load() }
    }

    func newConversation() async {
        guard mode == .chat else { return }
        cancelPolling()
        isSwitchingConversation = true
        let expectedGeneration = generation
        defer { if generation == expectedGeneration { isSwitchingConversation = false } }
        do {
            let client = try clientProvider()
            let created = try await client.createConversation()
            guard generation == expectedGeneration else { return }
            let updated = try await client.listConversations()
            guard generation == expectedGeneration else { return }
            conversations = updated
            error = nil
            activateConversation(created, client: client)
        } catch { guard generation == expectedGeneration else { return }; self.error = normalized(error) }
    }

    func selectConversation(id: String) async {
        guard mode == .chat else { return }
        cancelPolling()
        isSwitchingConversation = true
        let expectedGeneration = generation
        defer { if generation == expectedGeneration { isSwitchingConversation = false } }
        do {
            let client = try clientProvider()
            let selected = try await client.getConversation(id: id)
            guard generation == expectedGeneration else { return }
            error = nil
            activateConversation(selected, client: client)
        } catch { guard generation == expectedGeneration else { return }; self.error = normalized(error) }
    }

    func deleteCurrentConversation(deleteMemories: Bool = false) async {
        guard mode == .chat, let id = currentConversation?.id else { return }
        cancelPolling()
        isSwitchingConversation = true
        let expectedGeneration = generation
        defer { if generation == expectedGeneration { isSwitchingConversation = false } }
        do {
            let client = try clientProvider()
            try await client.deleteConversation(id: id, deleteMemories: deleteMemories)
            guard generation == expectedGeneration else { return }
            let remaining = try await client.listConversations()
            guard generation == expectedGeneration else { return }
            conversations = remaining
            if let next = remaining.first {
                let selected = try await client.getConversation(id: next.id)
                guard generation == expectedGeneration else { return }
                activateConversation(selected, client: client)
            } else {
                let created = try await client.createConversation()
                guard generation == expectedGeneration else { return }
                activateConversation(created, client: client)
            }
            pendingSubmission = nil
            error = nil
        } catch { guard generation == expectedGeneration else { return }; self.error = normalized(error) }
    }

    func confirmMemory(id: String) async {
        let expectedGeneration = generation
        do {
            let updated = try await clientProvider().confirmMemory(id: id)
            guard generation == expectedGeneration else { return }
            replaceMemory(updated)
        } catch { guard generation == expectedGeneration else { return }; self.error = normalized(error) }
    }

    func rejectMemory(id: String) async {
        let expectedGeneration = generation
        do {
            _ = try await clientProvider().rejectMemory(id: id)
            guard generation == expectedGeneration else { return }
            memories.removeAll { $0.id == id }
        } catch { guard generation == expectedGeneration else { return }; self.error = normalized(error) }
    }

    func deleteMemory(id: String) async {
        let expectedGeneration = generation
        do {
            try await clientProvider().deleteMemory(id: id)
            guard generation == expectedGeneration else { return }
            memories.removeAll { $0.id == id }
        } catch { guard generation == expectedGeneration else { return }; self.error = normalized(error) }
    }

    func editMemory(id: String, kind: UserMemoryKind, text: String) async {
        let expectedGeneration = generation
        do {
            let updated = try await clientProvider().editMemory(id: id, kind: kind, text: text)
            guard generation == expectedGeneration else { return }
            replaceMemory(updated)
        } catch { guard generation == expectedGeneration else { return }; self.error = normalized(error) }
    }

    func clearMemories() async {
        let expectedGeneration = generation
        do {
            try await clientProvider().clearMemories()
            guard generation == expectedGeneration else { return }
            memories = []
        } catch { guard generation == expectedGeneration else { return }; self.error = normalized(error) }
    }

    func setProactiveMemory(_ enabled: Bool) async {
        let expectedGeneration = generation
        do {
            let updated = try await clientProvider().setProactiveMemory(enabled)
            guard generation == expectedGeneration else { return }
            memoryPreferences = updated
        } catch { guard generation == expectedGeneration else { return }; self.error = normalized(error) }
    }

    private func finishSubmitting() {
        isSubmitting = false
        submissionTask = nil
    }

    private func activateConversation(_ conversation: Conversation, client: any AgentConversing) {
        if currentConversation?.id != conversation.id {
            pendingSubmission = nil
            minimumRevision = 0
        }
        if conversation.revision >= minimumRevision {
            applyConversation(conversation)
        }
        persistSelection(conversation.id)
        startObservingIfNeeded(client: client)
    }

    private func applyConversation(_ conversation: Conversation) {
        minimumRevision = conversation.revision
        currentConversation = conversation
        messages = conversation.messages
        let summary = ConversationSummary(id: conversation.id, title: conversation.title, updatedAt: conversation.updatedAt)
        if let index = conversations.firstIndex(where: { $0.id == summary.id }) {
            conversations[index] = summary
        } else {
            conversations.insert(summary, at: 0)
        }
    }

    private func refreshAndObserve(client: any AgentConversing, conversationID: String, expectedGeneration: UUID) async {
        do {
            try await refreshConversation(client: client, conversationID: conversationID, expectedGeneration: expectedGeneration)
            guard generation == expectedGeneration, !Task.isCancelled else { return }
            startObservingIfNeeded(client: client)
        } catch {
            guard generation == expectedGeneration, !Task.isCancelled else { return }
            if error == nil { self.error = normalized(error) }
        }
    }

    private func refreshConversation(client: any AgentConversing, conversationID: String, expectedGeneration: UUID) async throws {
        let refreshed = try await client.getConversation(id: conversationID)
        guard generation == expectedGeneration, !Task.isCancelled, let current = currentConversation,
              current.id == conversationID, refreshed.id == conversationID,
              refreshed.revision >= minimumRevision else { return }
        let messagesWereAdded = refreshed.messages.count > current.messages.count
        applyConversation(refreshed)
        if supportsMemories, messagesWereAdded {
            Task { [weak self] in
                guard let updated = try? await client.listMemories(),
                      let self, self.generation == expectedGeneration,
                      self.currentConversation?.messages.count == refreshed.messages.count else { return }
                self.memories = updated
            }
        }
    }

    private func startObservingIfNeeded(client: any AgentConversing) {
        guard observationTask == nil, let conversation = currentConversation,
              conversation.activeTurnID != nil || (conversation.queueBlockedByTurnID == nil && !queuedTurns.isEmpty) else { return }
        let expectedGeneration = generation
        let conversationID = conversation.id
        isObserving = true
        observationTask = Task { [weak self, client] in
            guard let self else { return }
            defer {
                if self.generation == expectedGeneration {
                    self.isObserving = false
                    self.observationTask = nil
                }
            }
            var handoffDelay: UInt64 = 100
            do {
                while self.generation == expectedGeneration, !Task.isCancelled, let current = self.currentConversation {
                    if let activeTurnID = current.activeTurnID {
                        _ = try await client.observeTurn(conversationID: conversationID, turnID: activeTurnID)
                        handoffDelay = 100
                    } else if current.queueBlockedByTurnID == nil && current.turns.contains(where: { $0.status == .queued }) {
                        try await Task.sleep(for: .milliseconds(handoffDelay))
                        handoffDelay = min(handoffDelay * 2, 2_000)
                    } else {
                        break
                    }
                    guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                    try await self.refreshConversation(client: client, conversationID: conversationID, expectedGeneration: expectedGeneration)
                    if let activeTurnID = current.activeTurnID, self.currentConversation?.activeTurnID == activeTurnID {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
            } catch {
                guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                if self.error == nil { self.error = self.normalized(error) }
            }
        }
    }

    private func selectedConversationID(from summaries: [ConversationSummary]) -> String? {
        let saved = defaults.string(forKey: selectionKey())
        if let saved, summaries.contains(where: { $0.id == saved }) { return saved }
        return summaries.first?.id
    }

    private func persistSelection(_ id: String) { defaults.set(id, forKey: selectionKey()) }

    private func selectionKey() -> String {
        "analysis.chat.last." + Data(serviceScope().utf8).base64EncodedString()
    }

    private func replaceMemory(_ memory: UserMemory) {
        if let index = memories.firstIndex(where: { $0.id == memory.id }) { memories[index] = memory }
        else { memories.append(memory) }
    }

    private func normalized(_ error: Error) -> AgentClientError {
        (error as? AgentClientError) ?? .invalidResponse
    }
}
