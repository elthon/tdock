import SwiftUI
import TDockCore
import UniformTypeIdentifiers

/// 密钥库：生成 Ed25519 / 导入已有私钥、查看/复制/分享公钥、一键部署到服务器、删除。私钥不会显示或导出。
struct KeysView: View {
    @EnvironmentObject private var keys: KeyLibrary
    @EnvironmentObject private var store: ServerStore
    @State private var naming = false
    @State private var importing = false
    @State private var newName = ""
    @State private var error: String?
    @State private var pendingDelete: KeyLibrary.Key?

    var body: some View {
        List {
            if keys.keys.isEmpty {
                Text("还没有密钥。可以生成新的 Ed25519 密钥，或导入已有的私钥；然后在密钥详情中“部署到服务器”。")
                    .foregroundStyle(.secondary)
            }
            ForEach(keys.keys) { key in
                NavigationLink {
                    KeyDetailView(key: key)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(key.name).font(.headline)
                            Text(key.typeName).font(.caption2).foregroundStyle(.secondary)
                        }
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
                Menu {
                    Button { newName = ""; naming = true } label: { Label("生成 Ed25519 密钥", systemImage: "wand.and.stars") }
                    Button { importing = true } label: { Label("导入已有私钥", systemImage: "square.and.arrow.down") }
                } label: {
                    Label("添加密钥", systemImage: "plus")
                }
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
        .sheet(isPresented: $importing) { KeyImportView() }
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

/// 导入已有私钥：粘贴或从“文件”选取。
private struct KeyImportView: View {
    @EnvironmentObject private var keys: KeyLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var pem = ""
    @State private var pickingFile = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（可选）", text: $name)
                }
                Section {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $pem)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 180)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if pem.isEmpty {
                            Text("粘贴 OpenSSH 私钥\n-----BEGIN OPENSSH PRIVATE KEY-----\n…")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    Button { pickingFile = true } label: { Label("从“文件”中选择…", systemImage: "folder") }
                } header: {
                    Text("私钥")
                } footer: {
                    Text("支持未加密的 Ed25519 / ECDSA OpenSSH 私钥（不支持 RSA 和带口令的私钥，可先用 ssh-keygen -p 去掉口令）。私钥只保存在本机 Keychain，不会同步。")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("导入私钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("导入", action: save) }
            }
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.data, .text, .item]) { result in
                switch result {
                case .success(let url): load(url)
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // 私钥文件很小；超过 64 KB 的肯定不是 OpenSSH 私钥。
        guard let data = try? Data(contentsOf: url), data.count < 64 * 1024,
              let text = String(data: data, encoding: .utf8) else {
            error = "无法读取该文件，或它不是文本格式的私钥"
            return
        }
        pem = text
        if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        error = nil
    }

    private func save() {
        do {
            try keys.importKey(name: name, privateKeyPEM: pem)
            pem = ""
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct KeyDetailView: View {
    let key: KeyLibrary.Key
    @State private var copied = false
    @State private var deploying = false

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
            Section {
                Button { deploying = true } label: {
                    Label("部署到服务器…", systemImage: "server.rack")
                }
            } footer: {
                Text("用服务器当前的密码（或已有凭据）临时登录一次，把公钥安全地追加到 ~/.ssh/authorized_keys，验证可用后把该服务器切换为此密钥登录。也可手动在服务器上执行：echo '<公钥>' >> ~/.ssh/authorized_keys")
            }
            Section("信息") {
                LabeledContent("类型", value: key.typeName)
                LabeledContent("指纹") {
                    Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("添加时间") {
                    Text(key.createdAt, format: .dateTime.year().month().day().hour().minute())
                }
            }
        }
        .navigationTitle(key.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $deploying) { DeployKeyView(key: key) }
    }
}

/// 内置 ssh-copy-id：选择服务器 → 用密码/现有凭据登录 → 幂等追加公钥 → 用新密钥验证登录 → 切换服务器为密钥登录。
struct DeployKeyView: View {
    let key: KeyLibrary.Key

    @EnvironmentObject private var store: ServerStore
    @EnvironmentObject private var manager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var serverID: UUID?
    @State private var password = ""
    @State private var switchToKey = true
    @State private var state: DeployState = .idle

    enum DeployState: Equatable {
        case idle
        case running(String)
        case done(String)
        case failed(String)
    }

    private var server: ServerProfile? { store.servers.first { $0.id == serverID } }
    private var isRunning: Bool { if case .running = state { return true } else { return false } }

    var body: some View {
        NavigationStack {
            Form {
                Section("目标服务器") {
                    Picker("服务器", selection: $serverID) {
                        Text("请选择").tag(UUID?.none)
                        ForEach(store.servers) { server in
                            Text(server.displayName).tag(UUID?.some(server.id))
                        }
                    }
                    if let server, server.keyID == key.id {
                        Text("该服务器已在使用这把密钥。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    SecureField(hasSavedCredential ? "密码（留空则使用已保存的凭据）" : "登录密码", text: $password)
                        .textContentType(.password)
                    Toggle("成功后切换为此密钥登录", isOn: $switchToKey)
                } header: {
                    Text("临时登录")
                } footer: {
                    Text("这里输入的密码只用于本次登录，不会保存。切换为密钥登录后，本机保存的该服务器密码会被删除。")
                }
                Section {
                    Button(action: deploy) {
                        HStack {
                            Text("部署公钥")
                            Spacer()
                            if isRunning { ProgressView() }
                        }
                    }
                    .disabled(server == nil || isRunning)
                    switch state {
                    case .idle: EmptyView()
                    case .running(let step): Text(step).foregroundStyle(.secondary)
                    case .done(let message): Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let message): Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("部署公钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(state.isDone ? "完成" : "取消") { dismiss() } }
            }
            .interactiveDismissDisabled(isRunning)
        }
    }

    private var hasSavedCredential: Bool {
        guard let server else { return false }
        return (try? CredentialProvider.credential(for: server)) != nil
    }

    private func deploy() {
        guard let profile = server else { return }
        let typedPassword = password
        state = .running("正在登录 \(profile.host)…")
        Task {
            do {
                let login: SSHCredential? = typedPassword.isEmpty ? nil : .password(typedPassword)
                let admin = try await manager.makeClient(for: profile, credential: login)
                defer { admin.close() }

                state = .running("正在写入 authorized_keys…")
                let outcome = try await AuthorizedKeysInstaller.install(publicKey: key.publicKey, on: admin)

                state = .running("正在用新密钥验证登录…")
                guard let pem = try KeychainStore.load(for: key.id, kind: .libraryKey) else {
                    throw CredentialProvider.MissingCredential(kind: .libraryKey, hostID: profile.id)
                }
                let verify = try await manager.makeClient(for: profile, credential: .privateKey(OpenSSHPrivateKey.parse(pem)))
                verify.close()

                var message = outcome == .installed ? "已部署并验证可以登录" : "公钥已存在，验证可以登录"
                if switchToKey, var updated = store.servers.first(where: { $0.id == profile.id }) {
                    updated.authMethod = .privateKey
                    updated.keyID = key.id
                    try store.save(updated, secret: nil)
                    message += "；已切换为密钥登录"
                }
                password = ""
                state = .done(message)
            } catch {
                state = .failed(Self.describe(error))
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if error is CredentialProvider.MissingCredential {
            return "本机没有该服务器的凭据，请在上方输入登录密码"
        }
        if case .authenticationFailed = error as? SSHSessionError {
            return "登录失败：密码不正确，或部署后服务器仍不接受该密钥（检查 sshd 的 AuthorizedKeysFile / PubkeyAuthentication 配置）"
        }
        return error.localizedDescription
    }
}

private extension DeployKeyView.DeployState {
    var isDone: Bool { if case .done = self { return true } else { return false } }
}
