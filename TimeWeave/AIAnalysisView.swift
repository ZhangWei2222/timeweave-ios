import SwiftUI

@MainActor
struct AIAnalysisView: View {
    @StateObject private var model: AIChatViewModel
    @StateObject private var service: AnalysisServiceSettings
    @State private var showingServiceSettings = false
    @State private var showingMemories = false
    @State private var confirmingConversationDeletion = false
    let period: Int

    init(period: Int, store: TimeStore) {
        self.period = period
        let service = AnalysisServiceSettings()
        _service = StateObject(wrappedValue: service)
        _model = StateObject(wrappedValue: AIChatViewModel(
            clientProvider: { try service.makeClient() },
            serviceScope: { service.currentAddress }
        ) { try AnalysisSnapshotBuilder.build(ledger: store.ledger, period: period) })
    }

    var body: some View {
        VStack(spacing: 0) {
            serviceHeader
            Divider()
            timeline
            Divider()
            composer
        }
        .background(Palette.background)
        .navigationTitle("AI 时间分析")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.mode == .chat {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { Task { await model.newConversation() } } label: {
                        Label("新对话", systemImage: "square.and.pencil")
                    }.accessibilityIdentifier("newAnalysisConversation")
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    conversationMenu
                    Button { showingMemories = true } label: {
                        Label("AI 对我的了解", systemImage: "brain.head.profile")
                    }.accessibilityIdentifier("analysisMemories")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showingServiceSettings = true } label: {
                    Label("服务设置", systemImage: "gearshape")
                }.accessibilityIdentifier("analysisServiceSettings")
            }
        }
        .sheet(isPresented: $showingServiceSettings) {
            AnalysisServiceSettingsView(service: service, didChange: model.serviceConfigurationChanged)
        }
        .sheet(isPresented: $showingMemories) {
            MemoryManagementView(model: model)
        }
        .confirmationDialog("删除当前对话？", isPresented: $confirmingConversationDeletion, titleVisibility: .visible) {
            Button("删除对话", role: .destructive) { Task { await model.deleteCurrentConversation() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("对话记录会从当前分析服务删除；已经确认的长期记忆默认保留。")
        }
        .task { await model.load() }
        .onDisappear { model.cancelPolling() }
    }

    private var serviceHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("当前服务：\(service.environment.title)").font(.subheadline.weight(.semibold))
                Spacer()
                Text("近 \(period) 天").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(service.currentAddress).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if model.mode == .legacy {
                Label("当前服务不保存对话", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if model.messages.isEmpty && model.error == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.largeTitle)
                            .foregroundStyle(Palette.accent)
                        Text("开始一段分析").font(.headline)
                        Text("可以追问上一轮，也可以明确说“记住……”保存稳定目标。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                        .padding(.top, 48)
                }
                ForEach(model.messages) { message in
                    messageBubble(message)
                }
                if model.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Agent 正在分析…").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(12).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("analysisPending")
                }
                if let error = model.error {
                    Card {
                        Label("暂时无法分析", systemImage: "exclamationmark.triangle").font(.headline)
                        Text(error.localizedDescription).font(.subheadline)
                        if model.mode == .loading {
                            Button("重试") { Task { await model.load() } }
                        } else if error.retryable {
                            Button("重试", action: model.retry).disabled(!model.canSubmit)
                        }
                    }.accessibilityIdentifier("analysisError")
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("analysisTimeline")
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                Text(message.role == .user ? "你" : "TimeWeave")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(message.text).textSelection(.enabled)
                if message.role == .assistant {
                    Text("基于该轮提交时的已记录时间；未记录不代表没有发生。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(message.role == .user ? Palette.accent.opacity(0.15) : Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier(message.role == .user ? "userMessage" : "assistantMessage")
            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("继续追问，或说“记住……”", text: $model.draft, axis: .vertical)
                .lineLimit(2...6).textFieldStyle(.roundedBorder)
                .disabled(model.isLoading || model.mode == .loading)
                .accessibilityIdentifier("analysisComposer")
            HStack {
                Text("只发送聚合统计，不发送记录明细或备注。")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(action: model.submit) {
                    Label(model.isLoading ? "分析中" : "发送", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent).disabled(!model.canSubmit)
                .accessibilityIdentifier("sendAnalysisMessage")
            }
            if model.draft.unicodeScalars.count > 500 {
                Text("问题最多 500 字。请精简后再试。").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12).background(Palette.card)
    }

    private var conversationMenu: some View {
        Menu {
            ForEach(model.conversations) { conversation in
                Button {
                    Task { await model.selectConversation(id: conversation.id) }
                } label: {
                    if conversation.id == model.currentConversation?.id {
                        Label(conversation.title, systemImage: "checkmark")
                    } else {
                        Text(conversation.title)
                    }
                }
            }
            Divider()
            Button("删除当前对话", role: .destructive) { confirmingConversationDeletion = true }
        } label: {
            Label("对话", systemImage: "bubble.left.and.bubble.right")
        }
        .accessibilityIdentifier("analysisConversations")
    }
}

@MainActor
private struct MemoryManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AIChatViewModel

    var body: some View {
        NavigationStack {
            List {
                if model.memories.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "brain").font(.largeTitle)
                        Text("还没有长期记忆").font(.headline)
                        Text("你可以在对话中说“记住……”，也可以确认 AI 提出的候选。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                ForEach(model.memories) { memory in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(memory.text)
                        HStack {
                            Text(memory.kind.title).font(.caption).foregroundStyle(.secondary)
                            if memory.sensitivity == .sensitive {
                                Label("敏感", systemImage: "lock").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        if memory.status == .proposed {
                            HStack {
                                Button("确认记住") { Task { await model.confirmMemory(id: memory.id) } }
                                    .buttonStyle(.borderedProminent)
                                Button("不保存", role: .destructive) { Task { await model.rejectMemory(id: memory.id) } }
                            }
                        } else {
                            Button("删除", role: .destructive) { Task { await model.deleteMemory(id: memory.id) } }
                        }
                    }.padding(.vertical, 4)
                }
            }
            .navigationTitle("AI 对我的了解")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private extension UserMemoryKind {
    var title: String {
        switch self { case .goal: "目标"; case .preference: "偏好"; case .constraint: "约束" }
    }
}

@MainActor
private struct AnalysisServiceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var service: AnalysisServiceSettings
    let didChange: () -> Void
    @State private var draft: AnalysisServiceDraft
    @State private var error: String?
    @State private var notice: String?
    @State private var confirmingDelete = false

    init(service: AnalysisServiceSettings, didChange: @escaping () -> Void) {
        self.service = service
        self.didChange = didChange
        _draft = State(initialValue: AnalysisServiceDraft(service: service))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("请求环境", selection: $draft.environment) {
                        ForEach(AnalysisEnvironment.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                } footer: {
                    Text("保存后立即切换并取消当前请求，不会自动切到另一环境。已发出的请求无法从服务端撤回。")
                }
                if draft.environment == .local {
                    Section {
                        addressField("本地服务地址", text: $draft.localAddress)
                            .accessibilityIdentifier("localServiceAddress")
                    } header: { Text("本地服务") } footer: {
                        Text("模拟器使用 127.0.0.1；真机请填 Mac 的局域网地址，并允许本地网络权限。手机的 127.0.0.1 指手机自己。Mac 服务还需监听对应内网接口并允许防火墙访问。")
                    }
                } else {
                    Section {
                        addressField("HTTPS 远端地址", text: $draft.remoteAddress)
                            .accessibilityIdentifier("remoteServiceAddress")
                        SecureField("访问令牌（留空保留原令牌）", text: $draft.token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .privacySensitive().accessibilityIdentifier("remoteAccessToken")
                        if draft.remoteAddress == service.remoteAddress {
                            Button("删除已保存的远端令牌", role: .destructive) { confirmingDelete = true }
                        }
                    } header: { Text("远端服务") } footer: {
                        Text("只填 HTTPS 主机地址及可选端口，不加接口路径。这里使用 Agent 服务访问令牌，不是阿里云 AK 或百炼密钥；令牌仅保存在设备钥匙串，换地址需重新填写。远端服务必须配置访问令牌和 HTTPS。")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("serviceSettingsError") } }
                if let notice { Section { Text(notice).foregroundStyle(.secondary) } }
            }
            .navigationTitle("分析服务设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).accessibilityIdentifier("saveAnalysisService")
                }
            }
            .confirmationDialog("删除 \(service.remoteAddress) 的访问令牌？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("删除令牌", role: .destructive) {
                    do {
                        try service.removeRemoteToken()
                        didChange()
                        draft.token = ""
                        error = nil
                        notice = "令牌已立即删除。再次使用该远端地址时需要重新填写。"
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func addressField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text).keyboardType(.URL)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
    }

    private func save() {
        do {
            try draft.save(to: service)
            didChange()
            draft.token = ""
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
