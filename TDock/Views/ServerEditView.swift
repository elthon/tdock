import SwiftUI
import TDockCore

/// 新增 / 编辑服务器。密码或私钥只写入 Keychain，从不回显已保存的值。
struct ServerEditView: View {
    @EnvironmentObject private var store: ServerStore
    @Environment(\.dismiss) private var dismiss

    private let original: ServerProfile?
    /// 原配置在 Keychain 中是否已有凭据（只判断存在与否，不读取到界面）。
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

    /// 编辑时且认证方式未改变：允许凭据留空（沿用 Keychain 中已保存的）。
    private var canKeepSavedSecret: Bool {
        originalHasSecret && original?.authMethod == draft.authMethod
    }

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
                } header: {
                    Text("认证")
                } footer: {
                    Text(draft.authMethod == .password
                         ? "密码仅保存在本机 Keychain。"
                         : "私钥仅保存在本机 Keychain。支持未加密的 Ed25519 / ECDSA 私钥。")
                }

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

    private func save() {
        var profile = draft
        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
        profile.host = profile.host.trimmingCharacters(in: .whitespaces)
        profile.username = profile.username.trimmingCharacters(in: .whitespaces)
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
            errorMessage = profile.authMethod == .password ? "请填写密码" : "请粘贴私钥"
            return
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
