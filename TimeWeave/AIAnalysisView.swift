import AVFoundation
import SwiftUI
import VisionKit

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
                    if let changes = model.currentConversation?.turns.first(where: { $0.id == message.turnID })?.memoryChanges {
                        ForEach(changes) { change in
                            Label(change.status == .active ? "已记住：\(change.text)" : "待你确认：\(change.text)",
                                  systemImage: change.status == .active ? "checkmark.circle" : "questionmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
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
    @State private var editingMemory: UserMemory?
    @State private var editText = ""
    @State private var confirmingClear = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("允许 AI 提出候选记忆", isOn: Binding(
                        get: { model.memoryPreferences.proactiveEnabled },
                        set: { enabled in Task { await model.setProactiveMemory(enabled) } }
                    ))
                } footer: {
                    Text("关闭后，AI 不再主动提议；你明确说“记住……”仍然有效。")
                }
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
                        Text("来源：\(memory.origin == "explicit_user" ? "你明确要求" : "AI 候选") · \(memory.createdAt)")
                            .font(.caption2).foregroundStyle(.secondary)
                        if memory.status == .proposed {
                            HStack {
                                Button("确认记住") { Task { await model.confirmMemory(id: memory.id) } }
                                    .buttonStyle(.borderedProminent)
                                Button("不保存", role: .destructive) { Task { await model.rejectMemory(id: memory.id) } }
                            }
                        } else {
                            HStack {
                                Button("编辑") { editingMemory = memory; editText = memory.text }
                                Button("删除", role: .destructive) { Task { await model.deleteMemory(id: memory.id) } }
                            }
                        }
                    }.padding(.vertical, 4)
                }
            }
            .navigationTitle("AI 对我的了解")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !model.memories.isEmpty { Button("清空", role: .destructive) { confirmingClear = true } }
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .alert("编辑长期记忆", isPresented: Binding(get: { editingMemory != nil }, set: { if !$0 { editingMemory = nil } })) {
                TextField("记忆内容", text: $editText)
                Button("保存") {
                    guard let memory = editingMemory else { return }
                    Task { await model.editMemory(id: memory.id, kind: memory.kind, text: editText) }
                    editingMemory = nil
                }
                Button("取消", role: .cancel) { editingMemory = nil }
            }
            .confirmationDialog("清空全部长期记忆？", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { Task { await model.clearMemories() } }
                Button("取消", role: .cancel) {}
            }
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
    @State private var showingPairingScanner = false
    @State private var pairingInProgress = false

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
                        SecureField("局域网访问令牌（回环服务可留空）", text: $draft.token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .privacySensitive().accessibilityIdentifier("localAccessToken")
                        if draft.localAddress == service.localAddress {
                            Button("删除已保存的本地令牌", role: .destructive) { confirmingDelete = true }
                        }
                    } header: { Text("本地服务") } footer: {
                        Text("模拟器使用 127.0.0.1；真机请填 Mac 的局域网地址并填写服务令牌。手机的 127.0.0.1 指手机自己。Mac 服务还需监听对应内网接口并允许防火墙访问。")
                    }
                } else {
                    Section {
                        addressField("HTTPS 远端地址", text: $draft.remoteAddress)
                            .accessibilityIdentifier("remoteServiceAddress")
                        Button(action: openPairingScanner) {
                            Label("扫码配对", systemImage: "qrcode.viewfinder")
                        }.accessibilityIdentifier("scanRemotePairingCode")
                        SecureField("访问令牌（留空保留原令牌）", text: $draft.token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .privacySensitive().accessibilityIdentifier("remoteAccessToken")
                        if draft.remoteAddress == service.remoteAddress {
                            Button("删除已保存的远端令牌", role: .destructive) { confirmingDelete = true }
                        }
                    } header: { Text("远端服务") } footer: {
                        Text("扫描此服务生成的一次性二维码。配对后凭证会保存在设备钥匙串，以后可以直接使用。旧版服务仍可手动填写访问令牌。")
                    }
                }
                if pairingInProgress { ProgressView("正在配对…") }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("serviceSettingsError") } }
                if let notice { Section { Text(notice).foregroundStyle(.secondary) } }
            }
            .disabled(pairingInProgress)
            .navigationTitle("分析服务设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(pairingInProgress) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).accessibilityIdentifier("saveAnalysisService")
                        .disabled(pairingInProgress)
                }
            }
            .confirmationDialog("删除 \(draft.environment == .local ? service.localAddress : service.remoteAddress) 的访问令牌？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("删除令牌", role: .destructive) {
                    do {
                        try service.removeToken(environment: draft.environment)
                        didChange()
                        draft.token = ""
                        error = nil
                        notice = "令牌已立即删除。再次使用该远端地址时需要重新填写。"
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .interactiveDismissDisabled(pairingInProgress)
        .sheet(isPresented: $showingPairingScanner) {
            NavigationStack {
                PairingCodeScanner(onCode: acceptPairingCode) {
                    showingPairingScanner = false
                    error = "无法打开摄像头，请检查相机权限后重试。"
                }
                .navigationTitle("扫描设备配对码")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showingPairingScanner = false }
                    }
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

    private func openPairingScanner() {
        guard DataScannerViewController.isSupported else {
            error = "这台设备不支持扫码配对，请在支持相机扫码的 iPhone 上操作。"
            return
        }
        pairingInProgress = true
        error = nil
        Task {
            defer { pairingInProgress = false }
            guard await AVCaptureDevice.requestAccess(for: .video), DataScannerViewController.isAvailable else {
                error = "请在系统设置中允许时序使用相机，再尝试扫码。"
                return
            }
            showingPairingScanner = true
        }
    }

    private func acceptPairingCode(_ payload: String) {
        guard !pairingInProgress else { return }
        showingPairingScanner = false
        pairingInProgress = true
        let address = draft.remoteAddress
        Task {
            defer { pairingInProgress = false }
            do {
                try await service.pairRemote(qrPayload: payload, address: address)
                didChange()
                draft.token = ""
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

@MainActor
private struct PairingCodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onUnavailable: onUnavailable) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])])
        let coordinator = context.coordinator
        scanner.delegate = coordinator
        Task { @MainActor [weak scanner] in
            guard let scanner, scanner.delegate != nil else { return }
            do { try scanner.startScanning() }
            catch { coordinator.fail() }
        }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.delegate = nil
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        let onUnavailable: () -> Void
        private var finished = false

        init(onCode: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
            self.onCode = onCode
            self.onUnavailable = onUnavailable
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !finished else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item, let payload = barcode.payloadStringValue else { continue }
                finished = true
                scanner.stopScanning()
                onCode(payload)
                return
            }
        }

        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            fail()
        }

        func fail() {
            guard !finished else { return }
            finished = true
            onUnavailable()
        }
    }
}
