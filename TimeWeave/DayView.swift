import SwiftUI

struct EntryDraft: Identifiable {
    let id = UUID()
    let entry: TimeEntry?
}

struct DayView: View {
    @EnvironmentObject private var store: TimeStore
    @State private var selectedDate = Date()
    @State private var draft: EntryDraft?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let day = Calendar.current.dateInterval(of: .day, for: selectedDate)!
            let recorded = TimeStatistics.seconds(store.ledger.entries, in: day)
            let elapsed = max(0, min(day.duration, context.date.timeIntervalSince(day.start)))
            let slices = distribution(day: day, elapsed: elapsed, recorded: recorded)
            let entries = store.ledger.entries.filter { $0.start < day.end && $0.end > day.start }.sorted { $0.start < $1.start }
            ScrollView {
                VStack(spacing: 20) {
                    dateNavigation(now: context.date)
                    Card {
                        HStack {
                            Text("时间都去哪了").font(.headline)
                            Spacer()
                            Text(Calendar.current.isDateInToday(selectedDate) ? "今天" : selectedDate.formatted(.dateTime.month().day()))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        DistributionRing(slices: slices, total: day.duration, recorded: recorded)
                            .frame(maxWidth: .infinity)
                        VStack(spacing: 12) {
                            ForEach(slices) { slice in
                                HStack {
                                    Circle().fill(slice.color).frame(width: 9, height: 9)
                                    Text(slice.name).font(.subheadline)
                                    Spacer()
                                    Text(durationText(slice.seconds)).font(.subheadline.monospacedDigit())
                                    Text(slice.seconds / day.duration, format: .percent.precision(.fractionLength(0)))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                                }.accessibilityElement(children: .combine)
                            }
                        }
                        Text("占比以完整一天计算，灰色代表未记录的时间。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button { draft = EntryDraft(entry: nil) } label: {
                        Label("添加时间", systemImage: "plus").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 9)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("addTime")
                    Card {
                        HStack {
                            Text("当天记录").font(.headline)
                            Spacer()
                            Text("\(entries.count) 条").font(.caption).foregroundStyle(.secondary)
                        }
                        if entries.isEmpty {
                            EmptyState(icon: "pencil.and.outline", title: "从一段时间开始", detail: "记下刚刚做的事，慢慢看见自己的节奏。")
                        } else {
                            ForEach(entries) { entry in
                                Button { draft = EntryDraft(entry: entry) } label: { entryRow(entry, day: day) }
                                    .buttonStyle(.plain)
                                if entry.id != entries.last?.id { Divider() }
                            }
                        }
                    }
                }.padding(20)
            }
            .background(Palette.background)
        }
        .navigationTitle("时序")
        .sheet(item: $draft) { draft in EntryEditor(entry: draft.entry, date: selectedDate) }
    }

    private func distribution(day: DateInterval, elapsed: TimeInterval, recorded: TimeInterval) -> [DistributionSlice] {
        var slices = store.ledger.categories.compactMap { category -> DistributionSlice? in
            let seconds = TimeStatistics.seconds(store.ledger.entries, in: day, categoryID: category.id)
            guard seconds > 0 else { return nil }
            return DistributionSlice(id: category.id.uuidString, name: category.name, seconds: seconds, color: category.color.tint)
        }
        let missing = max(0, elapsed - recorded)
        if missing > 0 { slices.append(DistributionSlice(id: "missing", name: "未记录", seconds: missing, color: .secondary.opacity(0.32))) }
        let future = max(0, day.duration - max(elapsed, recorded))
        if future > 0 { slices.append(DistributionSlice(id: "future", name: "尚未到来", seconds: future, color: .secondary.opacity(0.1))) }
        return slices
    }

    private func dateNavigation(now: Date) -> some View {
        HStack {
            Button { moveDay(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 44) }
                .accessibilityLabel("前一天")
            DatePicker("日期", selection: $selectedDate, in: ...now, displayedComponents: .date)
                .labelsHidden().frame(maxWidth: .infinity)
            Button { moveDay(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 44) }
                .disabled(Calendar.current.startOfDay(for: selectedDate) >= Calendar.current.startOfDay(for: now))
                .accessibilityLabel("后一天")
            Button("今天") { selectedDate = now }.font(.subheadline)
        }
    }
    private func moveDay(_ count: Int) {
        if let day = Calendar.current.date(byAdding: .day, value: count, to: selectedDate) { selectedDate = min(day, Date()) }
    }
    private func entryRow(_ entry: TimeEntry, day: DateInterval) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                if let category = store.category(entry.categoryID) { CategoryDot(category: category).font(.subheadline.weight(.semibold)) }
                Spacer()
                Text(durationText(TimeStatistics.seconds([entry], in: day))).font(.subheadline.monospacedDigit())
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            if !entry.note.isEmpty { Text(entry.note).font(.subheadline).lineLimit(3) }
            Text("\(entry.start.formatted(.dateTime.month().day().hour().minute())) – \(entry.end.formatted(.dateTime.month().day().hour().minute()))")
                .font(.caption).foregroundStyle(.secondary)
            if entry.start < day.start || entry.end > day.end { Text("跨日记录 · 时长仅计算当天部分").font(.caption2).foregroundStyle(.secondary) }
        }.padding(.vertical, 5).contentShape(Rectangle())
    }
}
