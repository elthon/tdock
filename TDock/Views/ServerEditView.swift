import SwiftUI
import TDockCore

/// 新增 / 编辑服务器。密码或私钥只写入 Keychain，从不回显已保存的值。
struct ServerEditView: View {
    @EnvironmentObject private var store: ServerStore
    @EnvironmentObject private var keys: KeyLibrary
    @Environment(\.dismiss) private var dismiss

    private let original: ServerProfile?
    /// 原配置在 Keychain 中是否已有“该服务器专属”的凭据（只判断存在与否，不读取到界面）。
    private let originalHasSecret: Bool
    @State private var draft: ServerProfile
    @State private var portText: String
    @State private var secret = ""
    @State private var errorMessage: String?

    init(profile: ServerProfile?) {
        original = profile
        originalHasSecret = profile.map {
            (try? KeychainStore.load(for: $0.id, kind: .init($0.authMethod))) != nil
        } ?? false
        let draft = profile ?? ServerProfile()
        _draft = State(initialValue: draft)
        _portText = State(initialValue: String(draft.port))
    }

    /// 编辑时认证方式未变、且仍使用该服务器专属凭据：允许留空（沿用 Keychain 中已保存的）。
    private var canKeepSavedSecret: Bool {
        guard let original, originalHasSecret, original.authMethod == draft.authMethod else { return false }
        return draft.authMethod == .password || (original.keyID == nil && draft.keyID == nil)
    }

    private var usesLibraryKey: Bool { draft.authMethod == .privateKey && draft.keyID != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("名称（可选）", text: $draft.name)
                    TextField("主机", text: $draft.host)
                        .keyboardType(.URL)
                        .plainInput()
                    TextField("端口", text: $portText)
                        .keyboardType(.numberPad)
                    TextField("用户名", text: $draft.username)
                        .plainInput()
                }

                Section {
                    HStack {
                        TextField("分组（可选）", text: $draft.group)
                        let groups = ServerListOrganizer.groupNames(store.servers)
                        if !groups.isEmpty {
                            Menu {
                                ForEach(groups, id: \.self) { group in
                                    Button(group) { draft.group = group }
                                }
                            } label: {
                                Image(systemName: "chevron.up.chevron.down")
                            }
                            .accessibilityLabel("选择已有分组")
                        }
                    }
                    Toggle("置顶", isOn: $draft.pinned)
                } header: {
                    Text("整理")
                }

                Section {
                    Picker("连接方式", selection: $draft.transport) {
                        Text("SSH").tag(ServerProfile.Transport.ssh)
                        Text("Mosh").tag(ServerProfile.Transport.mosh)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("连接方式")
                } footer: {
                    Text(draft.transport == .mosh
                         ? "Mosh 先用 SSH 登录启动 mosh-server，之后走 UDP：切换网络、短暂断线、锁屏后会话不断，打字有本地回显。需要服务器安装 mosh 并放行 UDP 60000–61000。"
                         : "标准 SSH 终端。")
                }

                authSection

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(original == nil ? "新增服务器" : "编辑服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                }
            }
        }
    }

    private var authSection: some View {
        Section {
            Picker("认证方式", selection: $draft.authMethod) {
                Text("密码").tag(ServerProfile.AuthMethod.password)
                Text("私钥").tag(ServerProfile.AuthMethod.privateKey)
            }
            .pickerStyle(.segmented)
            .onChange(of: draft.authMethod) { _ in secret = "" }

            switch draft.authMethod {
            case .password:
                SecureField(canKeepSavedSecret ? "已保存，留空则不修改" : "密码", text: $secret)
                    .textContentType(.password)
            case .privateKey:
                Picker("私钥", selection: $draft.keyID) {
                    Text("粘贴私钥").tag(UUID?.none)
                    ForEach(keys.keys) { key in
                        Text(key.name).tag(UUID?.some(key.id))
                    }
                }
                if let key = keys.key(draft.keyID) {
                    Text(key.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                } else {
                    privateKeyEditor
                }
            }
        } header: {
            Text("认证")
        } footer: {
            Text(draft.authMethod == .password
                 ? "密码仅保存在本机 Keychain，不会同步到 iCloud。"
                 : "私钥仅保存在本机 Keychain，不会同步到 iCloud。支持未加密的 Ed25519 / ECDSA 私钥；也可在“设置 → 密钥库”中生成。")
        }
    }

    private var privateKeyEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $secret)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 160)
                .plainInput()
            if secret.isEmpty {
                Text(canKeepSavedSecret
                     ? "已保存，留空则不修改"
                     : "粘贴 OpenSSH 私钥\n-----BEGIN OPENSSH PRIVATE KEY-----\n…")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
    }

    private func save() {
        var profile = draft
        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
        profile.host = profile.host.trimmingCharacters(in: .whitespaces)
        profile.username = profile.username.trimmingCharacters(in: .whitespaces)
        profile.group = profile.groupName
        if profile.authMethod == .password { profile.keyID = nil }
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)) else {
            errorMessage = "端口必须是数字"
            return
        }
        profile.port = port
        if let error = profile.validationError() {
            errorMessage = error
            return
        }

        var newSecret: String? = nil
        if !usesLibraryKey {
            switch profile.authMethod {
            case .password:
                if !secret.isEmpty { newSecret = secret }
            case .privateKey:
                let pem = secret.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pem.isEmpty {
                    do {
                        _ = try OpenSSHPrivateKey.parse(pem)
                    } catch {
                        errorMessage = error.localizedDescription
                        return
                    }
                    newSecret = pem + "\n"
                }
            }
            if newSecret == nil && !canKeepSavedSecret {
                errorMessage = profile.authMethod == .password ? "请填写密码" : "请粘贴私钥或选择密钥库中的密钥"
                return
            }
        }

        do {
            try store.save(profile, secret: newSecret)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension View {
    /// 主机名、用户名、私钥等输入：关闭自动大写与自动纠错。
    func plainInput() -> some View {
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}
