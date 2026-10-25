import SwiftUI

struct EntryDraft: Identifiable {
    let id = UUID()
    let entry: TimeEntry?
    let interval: DateInterval?

    init(entry: TimeEntry) {
        self.entry = entry
        interval = nil
    }

    init(interval: DateInterval) {
        entry = nil
        self.interval = interval
    }
}

struct DayView: View {
    @EnvironmentObject private var store: TimeStore
    @State private var selectedDate = Date()
    @State private var draft: EntryDraft?
    @State private var timerError: String?
    @State private var confirmsTimerCancellation = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let day = Calendar.current.dateInterval(of: .day, for: selectedDate)!
            let recorded = TimeStatistics.seconds(store.ledger.entries, in: day)
            let elapsed = max(0, min(day.duration, context.date.timeIntervalSince(day.start)))
            let slices = distribution(day: day, elapsed: elapsed, recorded: recorded)
            let entries = store.ledger.entries
                .filter { $0.start < day.end && $0.end > day.start }
                .sorted { $0.start < $1.start }
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
                    Card {
                        HStack {
                            Text("当天记录").font(.headline)
                            Spacer()
                            Text("\(entries.count) 条").font(.caption).foregroundStyle(.secondary)
                        }
                        if entries.isEmpty {
                            EmptyState(icon: "pencil.and.outline", title: "从一段时间开始", detail: "点击下方开始计时，慢慢看见自己的节奏。")
                        } else {
                            ForEach(entries) { entry in
                                Button { draft = EntryDraft(entry: entry) } label: { entryRow(entry, day: day) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("timeEntry")
                                if entry.id != entries.last?.id { Divider() }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Palette.background)
            .accessibilityHidden(draft != nil)
        }
        .navigationTitle("时序")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TimerDock(
                activeTimerStart: store.ledger.activeTimerStart,
                start: startTimer,
                cancel: { confirmsTimerCancellation = true },
                stop: stopTimer
            )
            .accessibilityHidden(draft != nil)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .overlay {
            if let draft {
                GeometryReader { geometry in
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.32)
                            .ignoresSafeArea()
                            .accessibilityHidden(true)
                            .transition(.opacity)

                        EntryEditor(
                            entry: draft.entry,
                            date: selectedDate,
                            interval: draft.interval,
                            close: closeEditor
                        )
                        .frame(height: min(geometry.size.height, 780))
                        .background(Palette.background)
                        .clipShape(.rect(topLeadingRadius: 28, topTrailingRadius: 28))
                        .shadow(color: .black.opacity(0.18), radius: 24, y: -6)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("entryEditorOverlay")
                        .accessibilityAddTraits(.isModal)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .zIndex(10)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.88), value: draft?.id)
        .confirmationDialog("放弃本次计时？", isPresented: $confirmsTimerCancellation, titleVisibility: .visible) {
            Button("放弃计时", role: .destructive, action: cancelTimer)
            Button("继续计时", role: .cancel) { }
        } message: {
            Text("已经计过的时间不会保存。")
        }
        .alert("无法更新计时", isPresented: Binding(
            get: { timerError != nil },
            set: { if !$0 { timerError = nil } }
        )) {
            Button("好") { timerError = nil }
        } message: {
            Text(timerError ?? "请稍后重试。")
        }
    }

    private func startTimer() {
        let now = Date()
        do {
            try store.startTimer(at: now)
            selectedDate = now
        } catch {
            timerError = error.localizedDescription
        }
    }

    private func stopTimer() {
        do {
            draft = EntryDraft(interval: try store.stopTimer(at: Date()))
        } catch {
            timerError = error.localizedDescription
        }
    }

    private func cancelTimer() {
        do {
            try store.cancelTimer()
        } catch {
            timerError = error.localizedDescription
        }
    }

    private func closeEditor() {
        draft = nil
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
                Text(durationText(TimeStatistics.seconds([entry], in: day)))
                    .font(.subheadline.monospacedDigit())
                    .accessibilityIdentifier("entryDuration")
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            if !entry.note.isEmpty { Text(entry.note).font(.subheadline).lineLimit(3) }
            Text("\(entry.start.formatted(.dateTime.month().day().hour().minute())) – \(entry.end.formatted(.dateTime.month().day().hour().minute()))")
                .font(.caption).foregroundStyle(.secondary)
            if entry.start < day.start || entry.end > day.end { Text("跨日记录 · 时长仅计算当天部分").font(.caption2).foregroundStyle(.secondary) }
        }.padding(.vertical, 5).contentShape(Rectangle())
    }
}

private struct TimerDock: View {
    let activeTimerStart: Date?
    let start: () -> Void
    let cancel: () -> Void
    let stop: () -> Void

    var body: some View {
        if let activeTimerStart {
            HStack(spacing: 14) {
                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("取消计时")
                .accessibilityIdentifier("cancelTimer")

                Image(systemName: "clock")
                    .font(.title2)
                    .foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在计时").font(.headline)
                    HStack(spacing: 6) {
                        Text(activeTimerStart.formatted(date: .omitted, time: .shortened))
                        Text("开始 ·")
                        Text(activeTimerStart, style: .timer).monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: stop) {
                    Image(systemName: "checkmark")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Palette.accent, in: Circle())
                }
                .accessibilityLabel("结束计时")
                .accessibilityIdentifier("stopTimer")
            }
            .padding(10)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.accent.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        } else {
            HStack(spacing: 0) {
                Button(action: start) {
                    HStack(spacing: 12) {
                        Text("开始")
                        Image(systemName: "plus")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Palette.accent, in: Circle())
                    }
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("startTimer")

                Divider().frame(height: 30)

                HStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.title3)
                        .frame(width: 48, height: 48)
                    Text("结束")
                }
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("结束，尚未开始计时")
            }
            .font(.headline)
            .padding(6)
            .background(Palette.card, in: Capsule())
            .overlay(Capsule().stroke(Color.secondary.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        }
    }
}
