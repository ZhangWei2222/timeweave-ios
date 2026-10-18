import SwiftUI

struct EntryEditor: View {
    @EnvironmentObject private var store: TimeStore
    @Environment(\.dismiss) private var dismiss
    private let existing: TimeEntry?
    @State private var start: Date
    @State private var end: Date
    @State private var note: String
    @State private var categoryID: UUID?
    @State private var error: String?
    @State private var confirmDelete = false

    init(entry: TimeEntry?, date: Date) {
        existing = entry
        let cal = Calendar.current
        let now = cal.dateInterval(of: .minute, for: Date())!.start
        let defaultEnd = cal.isDateInToday(date) ? now : cal.date(bySettingHour: 10, minute: 0, second: 0, of: date)!
        _start = State(initialValue: entry?.start ?? defaultEnd.addingTimeInterval(-3600))
        _end = State(initialValue: entry?.end ?? defaultEnd)
        _note = State(initialValue: entry?.note ?? "")
        _categoryID = State(initialValue: entry?.categoryID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("开始", selection: $start, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("结束", selection: $end, displayedComponents: [.date, .hourAndMinute])
                    LabeledContent("时长", value: end > start ? durationText(end.timeIntervalSince(start)) : "请调整起止时间")
                } footer: { Text("支持跨日补录；时间不能重叠，结束时间不能晚于现在。") }
                Section("分类") {
                    Picker("选择分类", selection: $categoryID) {
                        ForEach(store.ledger.categories) { Text($0.name).tag(Optional($0.id)) }
                    }.pickerStyle(.menu)
                }
                Section("描述（选填）") {
                    TextField("这段时间做了什么？", text: $note, axis: .vertical)
                        .lineLimit(3...6).accessibilityIdentifier("entryNote")
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.subheadline) } }
                if existing != nil { Section { Button("删除这条记录", role: .destructive) { confirmDelete = true } } }
            }
            .navigationTitle(existing == nil ? "添加时间" : "编辑时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).fontWeight(.semibold).accessibilityIdentifier("saveEntry") }
            }
            .onAppear { if categoryID == nil { categoryID = store.ledger.categories.first?.id } }
            .confirmationDialog("删除后，这段时间将从所有统计中移除。", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除记录", role: .destructive) {
                    guard let existing else { return }
                    do { try store.deleteEntry(existing.id); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
                Button("取消", role: .cancel) { }
            }
        }
    }
    private func save() {
        guard let categoryID else { error = "请先选择分类。"; return }
        let entry = TimeEntry(id: existing?.id ?? UUID(), start: start, end: end, note: note, categoryID: categoryID)
        do { try store.save(entry); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
