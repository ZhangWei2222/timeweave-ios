import SwiftUI

enum Palette {
    static let accent = Color(red: 0.10, green: 0.43, blue: 0.37)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
}

extension CategoryColor {
    var tint: Color {
        switch self {
        case .teal: return Color(red: 0.15, green: 0.55, blue: 0.47)
        case .blue: return Color(red: 0.29, green: 0.53, blue: 0.81)
        case .purple: return Color(red: 0.58, green: 0.45, blue: 0.73)
        case .orange: return Color(red: 0.85, green: 0.53, blue: 0.25)
        case .pink: return .pink
        case .green: return .green
        case .indigo: return .indigo
        case .brown: return .brown
        }
    }
    var title: String {
        switch self {
        case .teal: return "青绿"
        case .blue: return "蓝色"
        case .purple: return "紫色"
        case .orange: return "橙色"
        case .pink: return "粉色"
        case .green: return "绿色"
        case .indigo: return "靛蓝"
        case .brown: return "棕色"
        }
    }
}

func durationText(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int(seconds / 60))
    if seconds > 0 && minutes == 0 { return "不足 1 分钟" }
    if minutes < 60 { return "\(minutes) 分钟" }
    if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
    return "\(minutes / 60) 小时 \(minutes % 60) 分"
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 24))
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Palette.accent).padding(.bottom, 4)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}

struct CategoryDot: View {
    let category: TimeCategory
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(category.color.tint).frame(width: 9, height: 9)
            Text(category.name).lineLimit(2)
        }
    }
}

struct DistributionSlice: Identifiable {
    let id: String
    let name: String
    let seconds: TimeInterval
    let color: Color
}

struct DistributionRing: View {
    let slices: [DistributionSlice]
    let total: TimeInterval
    let recorded: TimeInterval
    private func start(_ index: Int) -> Double {
        slices.prefix(index).reduce(0) { $0 + $1.seconds } / max(total, 1)
    }
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.12), lineWidth: 26)
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                Circle()
                    .trim(from: start(index), to: min(1, start(index) + slice.seconds / max(total, 1)))
                    .stroke(slice.color, style: StrokeStyle(lineWidth: 26, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 6) {
                Text("已记录").font(.subheadline).foregroundStyle(.secondary)
                Text(durationText(recorded)).font(.title3.weight(.semibold)).minimumScaleFactor(0.7).lineLimit(1)
                Text("让时间有迹可循").font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
        .frame(width: 216, height: 216).padding(16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("时间分布，已记录\(durationText(recorded))")
    }
}
