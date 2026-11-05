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

protocol AIChatService: AgentConversing, AgentAnalyzing {}
extension AgentClient: AIChatService {}

enum AIChatMode: Equatable, Sendable {
    case loading
    case chat
    case legacy
}

@MainActor
final class AIChatViewModel: ObservableObject {
    @Published var draft = "分析这段时间的分配，指出最值得先关注的一点。"
    @Published private(set) var mode: AIChatMode = .loading
    @Published private(set) var conversations: [ConversationSummary] = []
    @Published private(set) var currentConversation: Conversation?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var memories: [UserMemory] = []
    @Published private(set) var memoryPreferences = MemoryPreferences(proactiveEnabled: true)
    @Published private(set) var isLoading = false
    @Published private(set) var error: AgentClientError?

    private struct PendingSubmission {
        let question: String
        let messageID: String
    }

    private let clientProvider: @MainActor () throws -> any AIChatService
    private let serviceScope: @MainActor () -> String
    private let defaults: UserDefaults
    private let snapshotBuilder: @MainActor () throws -> AnalysisSnapshot
    private var pendingSubmission: PendingSubmission?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(clientProvider: @escaping @MainActor () throws -> any AIChatService,
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
        return !isLoading && mode != .loading && (1...500).contains(count) && (mode == .legacy || currentConversation != nil)
    }

    func load() async {
        let expectedGeneration = generation
        let client: any AIChatService
        do { client = try clientProvider() }
        catch {
            guard generation == expectedGeneration else { return }
            self.error = normalized(error)
            mode = .loading
            return
        }
        do {
            let capabilities = try await client.capabilities()
            guard capabilities.schemaVersion == 1 else {
                throw AgentClientError.invalidResponse
            }
            guard capabilities.conversations else {
                guard generation == expectedGeneration else { return }
                mode = .legacy
                conversations = []; currentConversation = nil; memories = []; error = nil
                return
            }
            let summaries = try await client.listConversations()
            guard generation == expectedGeneration else { return }
            let selectedID = selectedConversationID(from: summaries)
            let selected: Conversation
            if let selectedID {
                selected = try await client.getConversation(id: selectedID)
            } else {
                selected = try await client.createConversation()
            }
            let refreshedSummaries = summaries.isEmpty ? [ConversationSummary(id: selected.id, title: selected.title, updatedAt: selected.updatedAt)] : summaries
            let loadedMemories = capabilities.memories ? try await client.listMemories() : []
            guard generation == expectedGeneration else { return }
            let loadedPreferences = capabilities.memories ? try await client.memoryPreferences() : MemoryPreferences(proactiveEnabled: false)
            guard generation == expectedGeneration else { return }
            mode = .chat
            conversations = refreshedSummaries
            currentConversation = selected
            messages = selected.messages
            memories = loadedMemories
            memoryPreferences = loadedPreferences
            error = nil
            persistSelection(selected.id)
            restorePendingTurnIfNeeded(client: client, conversation: selected, expectedGeneration: expectedGeneration)
        } catch let clientError as AgentClientError {
            guard generation == expectedGeneration else { return }
            if case .server(let code, _, _, _) = clientError, code == "not_found" || code == "method_not_allowed" {
                mode = .legacy
                conversations = []
                currentConversation = nil
                memories = []
                memoryPreferences = MemoryPreferences(proactiveEnabled: false)
                error = nil
            } else {
                mode = .loading
                error = clientError
            }
        } catch {
            guard generation == expectedGeneration else { return }
            mode = .loading
            self.error = normalized(error)
        }
    }

    func submit() {
        guard canSubmit else { return }
        let client: any AIChatService
        do { client = try clientProvider() }
        catch { self.error = normalized(error); return }
        let snapshot: AnalysisSnapshot
        do { snapshot = try snapshotBuilder() }
        catch {
            self.error = .server(code: "snapshot_invalid", message: "无法生成统计快照，请检查本地记录。", retryable: false, runID: nil)
            return
        }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageID: String
        if let pendingSubmission, pendingSubmission.question == question {
            messageID = pendingSubmission.messageID
        } else {
            messageID = UUID().uuidString.lowercased()
            pendingSubmission = PendingSubmission(question: question, messageID: messageID)
        }
        let expectedGeneration = generation
        let submittedMode = mode
        let conversationID = currentConversation?.id
        isLoading = true
        error = nil
        task?.cancel()
        task = Task { [weak self, client] in
            guard let self else { return }
            do {
                switch submittedMode {
                case .chat:
                    guard let conversationID else { throw AgentClientError.invalidResponse }
                    let turn = try await client.sendMessage(conversationID: conversationID, messageID: messageID, question: question, periodDays: snapshot.days.count, snapshot: snapshot)
                    try self.validateTerminal(turn)
                    let refreshed = try await client.getConversation(id: conversationID)
                    guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                    let refreshedMemories = try await client.listMemories()
                    guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                    let refreshedSummaries = try await client.listConversations()
                    guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                    self.currentConversation = refreshed
                    self.messages = refreshed.messages
                    self.memories = refreshedMemories
                    self.conversations = refreshedSummaries
                    self.persistSelection(refreshed.id)
                case .legacy:
                    let response = try await client.analyze(question: question, snapshot: snapshot)
                    guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                    let now = ISO8601DateFormatter().string(from: Date())
                    self.messages.append(ChatMessage(id: "local-user-\(messageID)", turnID: response.runID, role: .user, text: question, createdAt: now))
                    self.messages.append(ChatMessage(id: "local-assistant-\(response.runID)", turnID: response.runID, role: .assistant, text: response.answer, createdAt: now))
                case .loading:
                    throw AgentClientError.configuration("分析服务仍在连接，请稍后再试。")
                }
                guard self.generation == expectedGeneration else { return }
                self.pendingSubmission = nil
                self.draft = ""
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                self.error = self.normalized(error)
            }
            guard self.generation == expectedGeneration else { return }
            self.isLoading = false
            self.task = nil
        }
    }

    func retry() { submit() }

    func cancelPolling() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
    }

    func serviceConfigurationChanged() {
        cancelPolling()
        pendingSubmission = nil
        mode = .loading
        conversations = []
        currentConversation = nil
        messages = []
        memories = []
        memoryPreferences = MemoryPreferences(proactiveEnabled: true)
        error = nil
        let expectedGeneration = generation
        task = Task { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            await self.load()
        }
    }

    func newConversation() async {
        guard mode == .chat else { return }
        invalidateCurrentOperation()
        let expectedGeneration = generation
        do {
            let client = try clientProvider()
            let created = try await client.createConversation()
            guard generation == expectedGeneration else { return }
            let updated = try await client.listConversations()
            guard generation == expectedGeneration else { return }
            conversations = updated
            currentConversation = created
            messages = created.messages
            pendingSubmission = nil
            error = nil
            persistSelection(created.id)
        } catch { guard generation == expectedGeneration else { return }; self.error = normalized(error) }
    }

    func selectConversation(id: String) async {
        guard mode == .chat else { return }
        invalidateCurrentOperation()
        let expectedGeneration = generation
        do {
            let client = try clientProvider()
            let selected = try await client.getConversation(id: id)
            guard generation == expectedGeneration else { return }
            currentConversation = selected
            messages = selected.messages
            pendingSubmission = nil
            error = nil
            persistSelection(id)
            restorePendingTurnIfNeeded(client: client, conversation: selected, expectedGeneration: expectedGeneration)
        } catch { guard generation == expectedGeneration else { return }; self.error = normalized(error) }
    }

    func deleteCurrentConversation(deleteMemories: Bool = false) async {
        guard mode == .chat, let id = currentConversation?.id else { return }
        invalidateCurrentOperation()
        let expectedGeneration = generation
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
                currentConversation = selected
                messages = selected.messages
                persistSelection(selected.id)
            } else {
                let created = try await client.createConversation()
                guard generation == expectedGeneration else { return }
                currentConversation = created
                messages = created.messages
                conversations = [ConversationSummary(id: created.id, title: created.title, updatedAt: created.updatedAt)]
                persistSelection(created.id)
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

    private func restorePendingTurnIfNeeded(client: any AIChatService, conversation: Conversation, expectedGeneration: UUID) {
        if let activeID = conversation.activeTurnID,
           let turn = conversation.turns.first(where: { $0.id == activeID && ($0.status == .accepted || $0.status == .running) }) {
            pendingSubmission = PendingSubmission(question: turn.question, messageID: turn.messageID)
            draft = turn.question
            isLoading = true
            task = Task { [weak self, client] in
                guard let self else { return }
                do {
                    let terminal = try await client.resumeTurn(conversationID: conversation.id, turnID: turn.id)
                    try self.validateTerminal(terminal)
                    let refreshed = try await client.getConversation(id: conversation.id)
                    guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                    let refreshedMemories = try await client.listMemories()
                    guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                    let refreshedSummaries = try await client.listConversations()
                    guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                    self.currentConversation = refreshed; self.messages = refreshed.messages
                    self.memories = refreshedMemories; self.conversations = refreshedSummaries
                    self.pendingSubmission = nil; self.draft = ""; self.error = nil
                } catch is CancellationError { return }
                catch {
                    guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                    self.error = self.normalized(error)
                }
                guard self.generation == expectedGeneration else { return }
                self.isLoading = false; self.task = nil
            }
        } else if let paused = conversation.turns.last(where: { $0.status == .paused && ($0.retryable ?? false) }) {
            pendingSubmission = PendingSubmission(question: paused.question, messageID: paused.messageID)
            draft = paused.question
            error = .server(code: paused.errorCode ?? "paused", message: paused.errorMessage ?? "分析暂时中断，可以重试。", retryable: true, runID: paused.runID)
        }
    }

    private func invalidateCurrentOperation() {
        generation = UUID()
        task?.cancel(); task = nil; isLoading = false; pendingSubmission = nil
    }

    private func validateTerminal(_ turn: ConversationTurn) throws {
        switch turn.status {
        case .completed:
            guard turn.answer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { throw AgentClientError.invalidResponse }
        case .paused, .needsAttention, .cancelled:
            throw AgentClientError.server(code: turn.errorCode ?? turn.status.rawValue,
                                          message: turn.errorMessage ?? "分析暂时中断，请重试。",
                                          retryable: turn.retryable ?? (turn.status == .paused),
                                          runID: turn.runID)
        case .accepted, .running:
            throw AgentClientError.invalidResponse
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
