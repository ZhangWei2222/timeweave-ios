import SwiftUI

struct CategoryDraft: Identifiable {
    let id = UUID()
    let category: TimeCategory?
}

struct CategoriesView: View {
    @EnvironmentObject private var store: TimeStore
    @State private var draft: CategoryDraft?
    var body: some View {
        List {
            Section {
                ForEach(store.ledger.categories) { category in
                    Button { draft = CategoryDraft(category: category) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "tag.fill").foregroundStyle(category.color.tint)
                                .frame(width: 38, height: 38).background(category.color.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(category.name).foregroundStyle(.primary)
                                Text("\(store.ledger.entries.filter { $0.categoryID == category.id }.count) 条记录")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 4)
                    }
                }
            } footer: { Text("每段时间只属于一个分类。修改名称与颜色会同步到历史记录；删除分类时可迁移记录。") }
            Section { Button { draft = CategoryDraft(category: nil) } label: { Label("新增分类", systemImage: "plus") } }
            Section {
                Label("数据仅保存在这台设备", systemImage: "iphone")
                Text("关闭或重启 App 后记录仍会保留。卸载 App 会删除本地数据，当前暂不支持云同步。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("我的分类")
        .sheet(item: $draft) { draft in CategoryEditor(category: draft.category) }
    }
}

struct CategoryEditor: View {
    @EnvironmentObject private var store: TimeStore
    @Environment(\.dismiss) private var dismiss
    let existing: TimeCategory?
    @State private var name: String
    @State private var color: CategoryColor
    @State private var replacement: UUID?
    @State private var error: String?
    @State private var confirmDelete = false

    init(category: TimeCategory?) {
        existing = category
        _name = State(initialValue: category?.name ?? "")
        _color = State(initialValue: category?.color ?? .teal)
    }
    private var recordCount: Int { store.ledger.entries.filter { $0.categoryID == existing?.id }.count }
    private var destinations: [TimeCategory] { store.ledger.categories.filter { $0.id != existing?.id } }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") { TextField("例如：运动", text: $name).accessibilityIdentifier("categoryName") }
                Section("颜色") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 65))], spacing: 14) {
                        ForEach(CategoryColor.allCases, id: \.self) { value in
                            Button { color = value } label: {
                                VStack(spacing: 7) {
                                    ZStack {
                                        Circle().fill(value.tint).frame(width: 36, height: 36)
                                        if color == value { Image(systemName: "checkmark").fontWeight(.bold).foregroundStyle(.white) }
                                    }
                                    Text(value.title).font(.caption).foregroundStyle(.primary)
                                }.frame(minHeight: 58)
                            }.buttonStyle(.plain).accessibilityLabel(value.title)
                                .accessibilityAddTraits(color == value ? [.isSelected] : [])
                        }
                    }.padding(.vertical, 8)
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.subheadline) } }
                if existing != nil {
                    Section {
                        if recordCount > 0 && !destinations.isEmpty {
                            Picker("将历史记录迁移到", selection: $replacement) {
                                Text("请选择分类").tag(Optional<UUID>.none)
                                ForEach(destinations) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                        Button("删除分类", role: .destructive) { confirmDelete = true }
                            .disabled(store.ledger.categories.count <= 1 || (recordCount > 0 && replacement == nil))
                    } footer: {
                        Text(store.ledger.categories.count <= 1 ? "至少需要保留一个分类。" : "此分类有 \(recordCount) 条记录。删除分类不会删除记录，请先选择迁移目标。")
                    }
                }
            }
            .navigationTitle(existing == nil ? "新增分类" : "编辑分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    do { try store.save(TimeCategory(id: existing?.id ?? UUID(), name: name, color: color)); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.fontWeight(.semibold).accessibilityIdentifier("saveCategory") }
            }
            .confirmationDialog("确认删除这个分类？历史记录会迁移到所选分类。", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除分类", role: .destructive) {
                    guard let existing else { return }
                    do { try store.deleteCategory(existing.id, replacement: replacement); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
                Button("取消", role: .cancel) { }
            }
        }
    }
}
