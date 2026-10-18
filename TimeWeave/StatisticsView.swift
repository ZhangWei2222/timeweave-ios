import SwiftUI
import Charts

struct DailyPoint: Identifiable {
    let date: Date
    let seconds: TimeInterval
    var id: Date { date }
}

struct DailyTrendChart: View {
    let points: [DailyPoint]
    var color = Palette.accent
    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("日期", point.date), y: .value("小时", point.seconds / 3600))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.18), color.opacity(0.01)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("日期", point.date), y: .value("小时", point.seconds / 3600))
                .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2.5))
            PointMark(x: .value("日期", point.date), y: .value("小时", point.seconds / 3600))
                .foregroundStyle(color).symbolSize(18)
        }
        .chartYScale(domain: 0...max(1, (points.map { $0.seconds / 3600 }.max() ?? 0) * 1.15))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month().day()) } }
        .chartYAxisLabel("小时").frame(height: 190)
        .accessibilityLabel("每日时长趋势，单位小时")
    }
}

struct StatisticsView: View {
    @EnvironmentObject private var store: TimeStore
    @State private var period = 7
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let days = TimeStatistics.days(ending: context.date, count: period)
            let range = DateInterval(start: days[0].start, end: days[days.count - 1].end)
            let total = TimeStatistics.seconds(store.ledger.entries, in: range)
            ScrollView {
                VStack(spacing: 20) {
                    Picker("统计范围", selection: $period) { Text("近 7 天").tag(7); Text("近 30 天").tag(30) }.pickerStyle(.segmented)
                    Card {
                        Text("把时间看得更清楚").font(.headline)
                        Text(durationText(total)).font(.largeTitle.weight(.semibold)).foregroundStyle(Palette.accent)
                        Text("\(range.start.formatted(.dateTime.month().day())) – \(context.date.formatted(.dateTime.month().day())) · 已记录时长")
                            .font(.caption).foregroundStyle(.secondary)
                        if total > 0 {
                            DailyTrendChart(points: days.map { DailyPoint(date: $0.start, seconds: TimeStatistics.seconds(store.ledger.entries, in: $0)) })
                        } else { EmptyState(icon: "chart.xyaxis.line", title: "趋势从记录开始", detail: "添加时间后，这里会呈现每天的变化。") }
                    }
                    Card {
                        Text("按分类查看").font(.headline)
                        Text("点击分类，查看每日变化和常见时段。").font(.caption).foregroundStyle(.secondary)
                        ForEach(store.ledger.categories.sorted {
                            TimeStatistics.seconds(store.ledger.entries, in: range, categoryID: $0.id) > TimeStatistics.seconds(store.ledger.entries, in: range, categoryID: $1.id)
                        }) { category in
                            let amount = TimeStatistics.seconds(store.ledger.entries, in: range, categoryID: category.id)
                            NavigationLink { CategoryStatisticsView(categoryID: category.id, period: period) } label: {
                                VStack(spacing: 10) {
                                    HStack {
                                        CategoryDot(category: category)
                                        Spacer()
                                        Text(durationText(amount)).font(.subheadline.monospacedDigit())
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                    }
                                    ProgressView(value: amount, total: max(total, 1)).tint(category.color.tint)
                                }.padding(.vertical, 6)
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(20)
            }.background(Palette.background)
        }.navigationTitle("时间统计")
    }
}

struct CategoryStatisticsView: View {
    @EnvironmentObject private var store: TimeStore
    let categoryID: UUID
    @State var period: Int
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let category = store.category(categoryID) {
                let days = TimeStatistics.days(ending: context.date, count: period)
                let range = DateInterval(start: days[0].start, end: days[days.count - 1].end)
                let total = TimeStatistics.seconds(store.ledger.entries, in: range, categoryID: categoryID)
                let hours = TimeStatistics.hourly(store.ledger.entries, in: range, categoryID: categoryID)
                ScrollView {
                    VStack(spacing: 20) {
                        Picker("统计范围", selection: $period) { Text("近 7 天").tag(7); Text("近 30 天").tag(30) }.pickerStyle(.segmented)
                        Card {
                            CategoryDot(category: category).font(.headline)
                            Text(durationText(total)).font(.largeTitle.weight(.semibold)).foregroundStyle(category.color.tint)
                            Text("所选区间累计 · 日均 \(durationText(total / Double(period)))（含无记录日）").font(.caption).foregroundStyle(.secondary)
                        }
                        if total == 0 {
                            Card { EmptyState(icon: "chart.bar", title: "这个分类还没有记录", detail: "在所选时间范围内添加记录，即可查看分布。") }
                        } else {
                            Card {
                                Text("每天的变化").font(.headline)
                                DailyTrendChart(points: days.map { DailyPoint(date: $0.start, seconds: TimeStatistics.seconds(store.ledger.entries, in: $0, categoryID: categoryID)) }, color: category.color.tint)
                            }
                            Card {
                                Text("通常在哪个时段").font(.headline)
                                Text("近 \(period) 天各小时累计分钟，跨小时记录按实际时长拆分。").font(.caption).foregroundStyle(.secondary)
                                Chart(0..<24, id: \.self) { hour in
                                    BarMark(x: .value("小时", hour), y: .value("分钟", hours[hour] / 60))
                                        .foregroundStyle(category.color.tint).cornerRadius(3)
                                }
                                .chartXScale(domain: -0.5...23.5)
                                .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                                    AxisValueLabel { if let hour = value.as(Int.self) { Text("\(hour)时") } }
                                } }
                                .chartYAxisLabel("分钟").frame(height: 190)
                                if let peak = hours.indices.max(by: { hours[$0] < hours[$1] }) {
                                    Label("最集中：\(peak):00–\(peak + 1):00 · \(durationText(hours[peak]))", systemImage: "clock")
                                        .font(.subheadline).foregroundStyle(category.color.tint)
                                }
                            }
                            Card {
                                Text("每日明细").font(.headline)
                                ForEach(days.reversed(), id: \.start) { day in
                                    HStack {
                                        Text(day.start.formatted(.dateTime.month().day().weekday()))
                                        Spacer()
                                        Text(durationText(TimeStatistics.seconds(store.ledger.entries, in: day, categoryID: categoryID))).monospacedDigit()
                                    }.font(.subheadline).accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }.padding(20)
                }.background(Palette.background).navigationTitle(category.name).navigationBarTitleDisplayMode(.inline)
            } else { EmptyState(icon: "tag", title: "分类已删除", detail: "返回统计页查看其他分类。") }
        }
    }
}
