import SwiftUI
import TDockCore

/// 设置 → 键盘 → 指令片段：增删改、排序。片段出现在 Agent 抽屉的“片段”菜单中，一键发送。
struct SnippetEditorView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var editing: Snippet?

    var body: some View {
        List {
            Section {
                Text("在终端快捷栏点 ✨ 打开 Agent 抽屉，再点“片段”按钮即可一键发送。开启“自动回车”会直接执行。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(settings.snippets) { snippet in
                    Button {
                        editing = snippet
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snippet.displayTitle).foregroundStyle(.primary)
                            if snippet.displayTitle != snippet.command {
                                Text(snippet.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if !snippet.sendReturn {
                                Text("不自动回车").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .onDelete { settings.snippets.remove(atOffsets: $0) }
                .onMove { settings.snippets.move(fromOffsets: $0, toOffset: $1) }
                if settings.snippets.count < Snippet.maxCount {
                    Button {
                        editing = Snippet(command: "")
                    } label: {
                        Label("添加片段", systemImage: "plus")
                    }
                }
            }
            Section {
                Button("恢复默认片段", role: .destructive) { settings.snippets = Snippet.defaults }
            }
        }
        .navigationTitle("指令片段")
        .toolbar { EditButton() }
        .sheet(item: $editing) { snippet in
            SnippetEditSheet(snippet: snippet) { saved in
                if let index = settings.snippets.firstIndex(where: { $0.id == saved.id }) {
                    settings.snippets[index] = saved
                } else {
                    settings.snippets.append(saved)
                }
            }
        }
    }
}

private struct SnippetEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var snippet: Snippet
    @State private var error: String?
    let onSave: (Snippet) -> Void

    init(snippet: Snippet, onSave: @escaping (Snippet) -> Void) {
        _snippet = State(initialValue: snippet)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（可选）", text: $snippet.title)
                    TextField("命令，例如 git status", text: $snippet.command, axis: .vertical)
                        .font(.body.monospaced())
                        .lineLimit(1...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("自动回车执行", isOn: $snippet.sendReturn)
                } footer: {
                    Text("关闭“自动回车”时只把命令填到提示符后，方便补充参数（例如 tail -f 后面接文件名）。请不要在片段中保存密码等敏感信息。")
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle(snippet.command.isEmpty ? "新建片段" : "编辑片段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let message = snippet.validationError {
                            error = message
                            return
                        }
                        onSave(snippet)
                        dismiss()
                    }
                }
            }
        }
    }
}
