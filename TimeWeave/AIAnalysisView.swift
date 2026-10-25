import SwiftUI

@MainActor
struct AIAnalysisView: View {
    @StateObject private var model: AIAnalysisViewModel
    @StateObject private var service: AnalysisServiceSettings
    @State private var showingServiceSettings = false
    let period: Int

    init(period: Int, store: TimeStore) {
        self.period = period
        let service = AnalysisServiceSettings()
        _service = StateObject(wrappedValue: service)
        _model = StateObject(wrappedValue: AIAnalysisViewModel(clientProvider: { try service.makeClient() }) {
            try AnalysisSnapshotBuilder.build(ledger: store.ledger, period: period)
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前服务：\(service.environment.title)").font(.subheadline.weight(.semibold))
                    Text(service.currentAddress).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Card {
                    Label("近 \(period) 天 · 只读分析", systemImage: "sparkles").font(.headline)
                    TextField("你想了解什么？", text: $model.question, axis: .vertical)
                        .lineLimit(3...8).textFieldStyle(.roundedBorder)
                        .disabled(model.isLoading).accessibilityIdentifier("analysisQuestion")
                    Text("仅发送时间范围、分类和每日汇总及你的问题，经当前服务转交百炼。问题、分类名称和回答会保存在\(service.environment == .local ? "本地服务所在的 Mac" : "远端服务器")的私有日志中。不会发送记录明细或备注。")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.question.unicodeScalars.count > 500 {
                        Text("问题最多 500 字。请精简后再试。").font(.caption).foregroundStyle(.red)
                    }
                    Button(action: model.submit) {
                        HStack {
                            if model.isLoading { ProgressView() }
                            Text(model.isLoading ? "正在分析…" : "开始分析")
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(!model.canSubmit)
                        .accessibilityIdentifier("submitAnalysis")
                }
                if let error = model.error {
                    Card {
                        Label("暂时无法分析", systemImage: "exclamationmark.triangle").font(.headline)
                        Text(error.localizedDescription).font(.subheadline)
                        if error.retryable { Button("重试", action: model.submit).disabled(!model.canSubmit) }
                    }.accessibilityIdentifier("analysisError")
                }
                if let response = model.response {
                    Card {
                        Label("分析结果", systemImage: "text.bubble").font(.headline)
                        Text(response.answer).textSelection(.enabled)
                        Text("基于提交时的已记录时间；未记录不代表没有发生。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.accessibilityIdentifier("analysisResult")
                }
            }.padding(20)
        }
        .background(Palette.background)
        .navigationTitle("AI 时间分析")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showingServiceSettings = true } label: {
                    Label("服务设置", systemImage: "gearshape")
                }.accessibilityIdentifier("analysisServiceSettings")
            }
        }
        .sheet(isPresented: $showingServiceSettings) {
            AnalysisServiceSettingsView(service: service, didChange: model.serviceConfigurationChanged)
        }
        .onDisappear { model.cancel() }
    }
}

@MainActor
private struct AnalysisServiceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var service: AnalysisServiceSettings
    let didChange: () -> Void
    @State private var environment: AnalysisEnvironment
    @State private var localAddress: String
    @State private var remoteAddress: String
    @State private var token = ""
    @State private var error: String?
    @State private var notice: String?
    @State private var confirmingDelete = false

    init(service: AnalysisServiceSettings, didChange: @escaping () -> Void) {
        self.service = service
        self.didChange = didChange
        _environment = State(initialValue: service.environment)
        _localAddress = State(initialValue: service.localAddress)
        _remoteAddress = State(initialValue: service.remoteAddress)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("请求环境", selection: $environment) {
                        ForEach(AnalysisEnvironment.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                } footer: {
                    Text("保存后立即切换并取消当前请求，不会自动切到另一环境。已发出的请求无法从服务端撤回。")
                }
                if environment == .local {
                    Section {
                        addressField("本地服务地址", text: $localAddress)
                            .accessibilityIdentifier("localServiceAddress")
                    } header: { Text("本地服务") } footer: {
                        Text("模拟器使用 127.0.0.1；真机请填 Mac 的局域网地址，并允许本地网络权限。手机的 127.0.0.1 指手机自己。Mac 服务还需监听对应内网接口并允许防火墙访问。")
                    }
                } else {
                    Section {
                        addressField("HTTPS 远端地址", text: $remoteAddress)
                            .accessibilityIdentifier("remoteServiceAddress")
                        SecureField("访问令牌（留空保留原令牌）", text: $token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .privacySensitive().accessibilityIdentifier("remoteAccessToken")
                        if remoteAddress == service.remoteAddress {
                            Button("删除已保存的远端令牌", role: .destructive) { confirmingDelete = true }
                        }
                    } header: { Text("远端服务") } footer: {
                        Text("只填 HTTPS 主机地址及可选端口，不加 /v1/analysis。这里使用服务访问令牌，不是阿里云 AK 或百炼密钥；令牌仅保存在设备钥匙串，换地址需重新填写。预填域名不表示入口已开通：目前 ECS 仅监听服务器回环地址，真机仍需安全网络通道。")
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
                        token = ""
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
            try service.save(environment: environment, localAddress: localAddress, remoteAddress: remoteAddress,
                             token: token.isEmpty ? nil : token)
            didChange()
            token = ""
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
