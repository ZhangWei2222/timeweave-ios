import SwiftUI

struct EntryEditor: View {
    @EnvironmentObject private var store: TimeStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let existing: TimeEntry?
    private let close: () -> Void
    @State private var start: Date
    @State private var end: Date
    @State private var note: String
    @State private var categoryID: UUID?
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var showsDateControls: Bool

    init(entry: TimeEntry?, date: Date, interval: DateInterval? = nil, close: @escaping () -> Void) {
        existing = entry
        self.close = close
        let cal = Calendar.current
        let now = cal.dateInterval(of: .minute, for: Date())!.start
        let defaultEnd = cal.isDateInToday(date) ? now : cal.date(bySettingHour: 10, minute: 0, second: 0, of: date)!
        let initialStart = entry?.start ?? interval?.start ?? defaultEnd.addingTimeInterval(-3600)
        let initialEnd = entry?.end ?? interval?.end ?? defaultEnd
        _start = State(initialValue: initialStart)
        _end = State(initialValue: initialEnd)
        _note = State(initialValue: entry?.note ?? "")
        _categoryID = State(initialValue: entry?.categoryID)
        _showsDateControls = State(initialValue: !cal.isDate(initialStart, inSameDayAs: initialEnd))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Capsule()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: 40, height: 4)
                HStack {
                    Text(existing == nil ? "确认时间" : "编辑时间")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if existing != nil {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Image(systemName: "trash")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 36, height: 36)
                                .background(Color.red.opacity(0.1), in: Circle())
                        }
                        .accessibilityLabel("删除这条记录")
                        .accessibilityIdentifier("deleteEntry")
                    }
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .background(Color.secondary.opacity(0.1), in: Circle())
                    }
                    .accessibilityLabel("关闭时间编辑")
                    .accessibilityIdentifier("closeEntryEditor")
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 7)
            .padding(.bottom, 6)

            VStack(spacing: 10) {
                timeCard
                categoryCard
                noteCard
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                        .accessibilityIdentifier("entryError")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Palette.background)

            Spacer(minLength: 0)

            Button(action: save) {
                Text("确定")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Palette.accent, in: Capsule())
            }
            .accessibilityIdentifier("saveEntry")
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(.bar)
            .confirmationDialog("删除后，这段时间将从所有统计中移除。", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除记录", role: .destructive) {
                    guard let existing else { return }
                    do { try store.deleteEntry(existing.id); close() }
                    catch { self.error = error.localizedDescription }
                }
                Button("取消", role: .cancel) { }
            }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var timeCard: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                timeSummary(title: "开始时间", date: start, alignment: .leading)
                Spacer(minLength: 8)
                Text(end > start ? durationText(end.timeIntervalSince(start)) : "时间无效")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(end > start ? Palette.accent : .red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background((end > start ? Palette.accent : Color.red).opacity(0.12), in: Capsule())
                    .lineLimit(1)
                Spacer(minLength: 8)
                timeSummary(title: "结束时间", date: end, alignment: .trailing)
            }

            Divider()

            if showsDateControls {
                HStack(spacing: 16) {
                    dateControl(title: "开始日期", selection: $start)
                    dateControl(title: "结束日期", selection: $end)
                }
            } else {
                HStack {
                    Text(start.formatted(.dateTime.year().month().day()))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("调整日期") { showsDateControls = true }
                }
                .font(.caption)
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 6) {
                    compactTimeControl(title: "开始时间", selection: $start)
                    compactTimeControl(title: "结束时间", selection: $end)
                }
            } else {
                GeometryReader { geometry in
                    let pickerWidth = max(0, (geometry.size.width - 17) / 2)
                    HStack(spacing: 8) {
                        wheelTimeControl(title: "开始", selection: $start)
                            .frame(width: pickerWidth)
                        Divider().frame(height: 92)
                        wheelTimeControl(title: "结束", selection: $end)
                            .frame(width: pickerWidth)
                    }
                }
                .frame(height: 104)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private var categoryCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("分类").font(.headline)
                Spacer()
                if categoryID == nil { Text("请选择").font(.caption).foregroundStyle(.secondary) }
            }
            LazyVGrid(columns: categoryColumns, spacing: 8) {
                ForEach(inlineCategories) { category in
                    categoryButton(category)
                }
                if !overflowCategories.isEmpty {
                    Menu {
                        ForEach(overflowCategories) { category in
                            Button(category.name) { selectCategory(category) }
                        }
                    } label: {
                        Label("更多", systemImage: "ellipsis")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("更多分类")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private var categoryColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.adaptive(minimum: 120), spacing: 10)]
        }
        return Array(repeating: GridItem(.flexible(minimum: 64), spacing: 8), count: 4)
    }

    private var categoryDisplayLimit: Int { dynamicTypeSize.isAccessibilitySize ? 4 : 8 }

    private var inlineCategories: [TimeCategory] {
        let categories = store.ledger.categories
        guard categories.count > categoryDisplayLimit else { return categories }
        let inlineCount = categoryDisplayLimit - 1
        var result = Array(categories.prefix(inlineCount))
        if let categoryID,
           let selected = categories.first(where: { $0.id == categoryID }),
           !result.contains(where: { $0.id == categoryID }) {
            result[result.count - 1] = selected
        }
        return result
    }

    private var overflowCategories: [TimeCategory] {
        let inlineIDs = Set(inlineCategories.map(\.id))
        return store.ledger.categories.filter { !inlineIDs.contains($0.id) }
    }

    private func selectCategory(_ category: TimeCategory) {
        categoryID = category.id
        error = nil
    }

    private func categoryButton(_ category: TimeCategory) -> some View {
        let selected = categoryID == category.id
        return Button {
            selectCategory(category)
        } label: {
            HStack(spacing: 6) {
                if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                Text(category.name).lineLimit(1)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(selected ? Color.white : category.color.tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(category.color.tint.opacity(selected ? 1 : 0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("分类，\(category.name)\(selected ? "，已选择" : "")")
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("备注").font(.headline)
            TextField("这段时间做了什么？", text: $note, axis: .vertical)
                .lineLimit(1...2)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("entryNote")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func timeSummary(title: String, date: Date, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(date.formatted(date: .omitted, time: .shortened)).font(.headline.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private func dateControl(title: String, selection: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            DatePicker(title, selection: selection, in: ...Date(), displayedComponents: .date)
                .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func wheelTimeControl(title: String, selection: Binding<Date>) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            DatePicker(title, selection: selection, in: ...Date(), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.wheel)
                .accessibilityIdentifier(title == "开始" ? "startTimePicker" : "endTimePicker")
                .frame(maxWidth: .infinity)
                .frame(height: 92)
                .clipped()
        }
    }

    private func compactTimeControl(title: String, selection: Binding<Date>) -> some View {
        HStack {
            Text(title)
            Spacer()
            DatePicker(title, selection: selection, in: ...Date(), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .accessibilityIdentifier(title == "开始时间" ? "startTimePicker" : "endTimePicker")
        }
    }

    private func save() {
        guard let categoryID else { error = "请先选择分类。"; return }
        let entry = TimeEntry(id: existing?.id ?? UUID(), start: start, end: end, note: note, categoryID: categoryID)
        do { try store.save(entry); close() }
        catch { self.error = error.localizedDescription }
    }
}
