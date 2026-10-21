import SwiftUI

@MainActor
struct AIAnalysisView: View {
    @StateObject private var model: AIAnalysisViewModel
    let period: Int

    init(period: Int, store: TimeStore) {
        self.period = period
        _model = StateObject(wrappedValue: AIAnalysisViewModel {
            try AnalysisSnapshotBuilder.build(ledger: store.ledger, period: period)
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    Label("近 \(period) 天 · 只读分析", systemImage: "sparkles").font(.headline)
                    TextField("你想了解什么？", text: $model.question, axis: .vertical)
                        .lineLimit(3...8).textFieldStyle(.roundedBorder)
                        .disabled(model.isLoading).accessibilityIdentifier("analysisQuestion")
                    Text("仅发送时间范围、分类和每日汇总及你的问题给百炼；问题、分类名称和回答会保存在 Mac 本机私有日志中。不会发送记录明细或备注。")
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
        .onDisappear { model.cancel() }
    }
}
