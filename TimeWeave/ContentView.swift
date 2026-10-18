import SwiftUI

struct ContentView: View {
    @StateObject private var store = TimeStore()

    var body: some View {
        Group {
            if let error = store.loadError {
                VStack(spacing: 24) {
                    EmptyState(icon: "externaldrive.badge.exclamationmark", title: "暂时无法读取记录", detail: error)
                    Button("重试读取") { store.reload() }.buttonStyle(.borderedProminent)
                }.padding()
            } else {
                TabView {
                    NavigationStack { DayView() }
                        .tabItem { Label("记录", systemImage: "clock") }
                    NavigationStack { StatisticsView() }
                        .tabItem { Label("统计", systemImage: "chart.xyaxis.line") }
                    NavigationStack { CategoriesView() }
                        .tabItem { Label("分类", systemImage: "tag") }
                }
                .environmentObject(store)
            }
        }
        .tint(Palette.accent)
        .environment(\.locale, Locale(identifier: "zh_CN"))
    }
}
