import SwiftUI
import TDockCore

/// 自定义快捷栏：每页的按键可增删、排序；可增删页面；可恢复默认。
struct ShortcutEditorView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var layout = ShortcutLayout.default
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                Text("快捷栏显示在键盘上方，左右滑动切换页面。长按 Ctrl 可弹出常用组合键；右侧 ✨ 按钮打开 Agent 抽屉（Esc、Tab、Ctrl+C、↑、↓）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(layout.pages.indices, id: \.self) { pageIndex in
                Section {
                    ForEach(Array(layout.pages[pageIndex].enumerated()), id: \.offset) { _, key in
                        HStack {
                            Text(key.label)
                                .font(.body.monospaced())
                                .frame(minWidth: 44, alignment: .leading)
                            Text(key.title).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        layout.pages[pageIndex].remove(atOffsets: offsets)
                        save()
                    }
                    .onMove { source, destination in
                        layout.pages[pageIndex].move(fromOffsets: source, toOffset: destination)
                        save()
                    }
                    if layout.pages[pageIndex].count < ShortcutLayout.maxKeysPerPage {
                        Menu {
                            ForEach(ShortcutKey.allCases) { key in
                                Button(key.title) {
                                    layout.pages[pageIndex].append(key)
                                    save()
                                }
                            }
                        } label: {
                            Label("添加按键", systemImage: "plus")
                        }
                    }
                } header: {
                    HStack {
                        Text("第 \(pageIndex + 1) 页")
                        Spacer()
                        if layout.pages.count > 1 {
                            Button("删除此页", role: .destructive) {
                                layout.pages.remove(at: pageIndex)
                                save()
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            Section {
                if layout.pages.count < ShortcutLayout.maxPages {
                    Button {
                        layout.pages.append([.esc, .tab])
                        save()
                    } label: {
                        Label("添加一页", systemImage: "plus.rectangle.on.rectangle")
                    }
                }
                Button("恢复默认", role: .destructive) {
                    layout = .default
                    save()
                }
            }
        }
        .navigationTitle("自定义快捷栏")
        .toolbar { EditButton() }
        .onAppear {
            guard !loaded else { return }
            layout = settings.shortcutLayout
            loaded = true
        }
    }

    private func save() {
        // 编辑过程中允许出现空页；保存时规范化（去空页，全空则恢复默认）。
        settings.shortcutLayout = layout.normalized()
    }
}
