import SwiftUI
import TDockCore

/// 密钥库：生成 Ed25519 密钥、查看/复制/分享公钥、删除。私钥不会显示或导出。
struct KeysView: View {
    @EnvironmentObject private var keys: KeyLibrary
    @EnvironmentObject private var store: ServerStore
    @State private var naming = false
    @State private var newName = ""
    @State private var error: String?
    @State private var pendingDelete: KeyLibrary.Key?

    var body: some View {
        List {
            if keys.keys.isEmpty {
                Text("还没有密钥。生成后把公钥加入服务器的 ~/.ssh/authorized_keys 即可使用。")
                    .foregroundStyle(.secondary)
            }
            ForEach(keys.keys) { key in
                NavigationLink {
                    KeyDetailView(key: key)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key.name).font(.headline)
                        Text(key.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .swipeActions {
                    Button("删除", role: .destructive) { pendingDelete = key }
                }
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .navigationTitle("密钥库")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { newName = ""; naming = true } label: { Label("生成密钥", systemImage: "plus") }
            }
        }
        .alert("生成 Ed25519 密钥", isPresented: $naming) {
            TextField("名称（可选）", text: $newName)
            Button("生成") {
                do {
                    try keys.generate(name: newName)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("私钥只保存在本机 Keychain 中。")
        }
        .confirmationDialog(
            "删除密钥？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { key in
            Button("删除 \(key.name)", role: .destructive) { keys.delete(key) }
        } message: { key in
            let users = store.servers.filter { $0.keyID == key.id }.map(\.displayName)
            Text(users.isEmpty
                 ? "私钥将从 Keychain 中永久删除，无法恢复。"
                 : "以下服务器正在使用该密钥，删除后将无法登录：\(users.joined(separator: "、"))")
        }
    }
}

private struct KeyDetailView: View {
    let key: KeyLibrary.Key
    @State private var copied = false

    var body: some View {
        List {
            Section("公钥") {
                Text(key.publicKey)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = key.publicKey
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制公钥", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: key.publicKey) {
                    Label("分享公钥", systemImage: "square.and.arrow.up")
                }
            }
            Section("信息") {
                LabeledContent("类型", value: "Ed25519")
                LabeledContent("指纹") {
                    Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("创建时间") {
                    Text(key.createdAt, format: .dateTime.year().month().day().hour().minute())
                }
            }
            Section {
                Text("在服务器上执行：\necho '<公钥>' >> ~/.ssh/authorized_keys")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            } header: {
                Text("使用方法")
            }
        }
        .navigationTitle(key.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
