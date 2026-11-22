import SwiftUI
import TDockCore

/// 单个终端 + 连接状态遮罩。
///
/// 遮罩在原地处理常见异常，不需要退回列表：
/// - 缺少凭据（iCloud 同步来的新设备）→ 补填表单，保存后直接重连；
/// - 主机指纹变更 → 安全警告 + 二次确认后更新信任记录并重连；
/// - 连接丢失 → 自动重连进度（第 n/3 次）+ “立即重连”。
struct TerminalPane: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var manager: SessionManager
    @State private var fillingCredential = false
    @State private var confirmingNewHostKey = false

    var body: some View {
        SwiftTermView(terminalView: session.terminalView)
            .overlay { statusOverlay }
            .overlay { PinchHUD(session: session) }
            .onAppear { _ = session.terminalView.becomeFirstResponder() }
            .onChange(of: session.issue) { issue in
                // 缺凭据时直接弹出补填表单。
                if case .missingCredential = issue { fillingCredential = true }
            }
            .sheet(isPresented: $fillingCredential) {
                if case .missingCredential(let kind) = session.issue {
                    CredentialFillView(hostID: session.hostID, kind: kind) {
                        manager.retryFailedTerminals(hostID: session.hostID)
                    }
                }
            }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch session.phase {
        case .connected:
            EmptyView()
        case .connecting:
            card {
                ProgressView().tint(.white)
                Text("正在连接 \(session.profile?.host ?? "")…").foregroundStyle(.white)
            }
        case .reconnecting(let attempt, let max):
            card {
                ProgressView().tint(.white)
                Text("连接已断开").font(.headline).foregroundStyle(.white)
                Text("正在尝试自动重连（\(attempt)/\(max)）…")
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
                Button("立即重连") { session.reconnectNow() }
                    .buttonStyle(.borderedProminent)
            }
        case .ended(let message):
            switch session.issue {
            case .missingCredential:
                card {
                    Image(systemName: "key.slash").font(.largeTitle).foregroundStyle(.yellow)
                    Text(message ?? "").multilineTextAlignment(.center).foregroundStyle(.white)
                    Button("填写凭据并连接") { fillingCredential = true }
                        .buttonStyle(.borderedProminent)
                }
            case .hostKeyMismatch(let host, let port, let expected, let actual):
                hostKeyMismatchCard(host: host, port: port, expected: expected, actual: actual)
            case nil:
                card {
                    Image(systemName: message == nil ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(message == nil ? Color.green : Color.yellow)
                    Text(message ?? "会话已结束")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                    Button("重新连接") { session.restart() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func hostKeyMismatchCard(host: String, port: Int, expected: String, actual: String) -> some View {
        card {
            Image(systemName: "exclamationmark.shield.fill").font(.largeTitle).foregroundStyle(.red)
            Text("主机指纹已变更").font(.headline).foregroundStyle(.white)
            Text("\(host):\(String(port)) 的主机密钥与之前记录的不一致。如果服务器刚重装系统或更换了主机密钥，这是正常的；否则可能存在中间人攻击，请先与管理员核对指纹。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.85))
            VStack(alignment: .leading, spacing: 6) {
                fingerprintLine("记录", expected, color: .secondary)
                fingerprintLine("当前", actual, color: .orange)
            }
            .padding(10)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            Button(role: .destructive) {
                confirmingNewHostKey = true
            } label: {
                Label("更新信任指纹并重连", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .confirmationDialog("确认信任新的主机密钥？", isPresented: $confirmingNewHostKey, titleVisibility: .visible) {
            Button("我已核对，信任并重连", role: .destructive) {
                manager.replaceTrustedHostKey(host: host, port: port, with: actual, hostID: session.hostID)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("新的指纹：\n\(actual)\n\n只有在确认服务器确实更换了主机密钥时才继续。")
        }
    }

    private func fingerprintLine(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.white.opacity(0.6))
            Text(value).font(.caption.monospaced()).foregroundStyle(color).textSelection(.enabled)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 14, content: content)
            .padding(24)
            .frame(maxWidth: 400)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .environment(\.colorScheme, .dark)
            .padding()
    }
}

/// 原地补填缺失的凭据：写入本机 Keychain（或改选密钥库中的密钥），完成后回调以重连。
struct CredentialFillView: View {
    let hostID: UUID
    let kind: CredentialProvider.MissingCredential.Kind
    let onSaved: () -> Void

    @EnvironmentObject private var store: ServerStore
    @EnvironmentObject private var keys: KeyLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var secret = ""
    @State private var libraryKeyID: UUID?
    @State private var error: String?

    private var profile: ServerProfile? { store.servers.first { $0.id == hostID } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let profile {
                        LabeledContent("服务器", value: "\(profile.username)@\(profile.host)")
                    }
                } footer: {
                    Text(explanation)
                }

                if kind == .password {
                    Section("密码") {
                        SecureField("密码", text: $secret)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .onSubmit(save)
                    }
                } else {
                    Section("私钥") {
                        Picker("使用", selection: $libraryKeyID) {
                            Text("粘贴私钥").tag(UUID?.none)
                            ForEach(keys.keys) { key in
                                Text(key.name).tag(UUID?.some(key.id))
                            }
                        }
                        if let key = keys.key(libraryKeyID) {
                            Text(key.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                        } else {
                            TextEditor(text: $secret)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 140)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("补填凭据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存并连接", action: save) }
            }
        }
    }

    private var explanation: String {
        switch kind {
        case .password:
            return "本机还没有这台服务器的密码（配置来自 iCloud 同步，凭据不会同步）。密码只保存在本机 Keychain。"
        case .privateKey:
            return "本机还没有这台服务器的私钥（配置来自 iCloud 同步，凭据不会同步）。粘贴私钥或选择密钥库中的密钥，只保存在本机 Keychain。"
        case .libraryKey:
            return "这台服务器配置为使用密钥库中的某把密钥，但本机没有它。可改选本机密钥库中的密钥，或直接粘贴私钥。"
        }
    }

    private func save() {
        guard var profile else { return dismiss() }
        do {
            switch kind {
            case .password:
                guard !secret.isEmpty else { error = "请填写密码"; return }
                try KeychainStore.save(secret, for: hostID, kind: .password)
            case .privateKey, .libraryKey:
                if let keyID = libraryKeyID {
                    profile.keyID = keyID
                    try store.save(profile, secret: nil)
                } else {
                    let pem = secret.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !pem.isEmpty else { error = "请粘贴私钥或选择密钥库中的密钥"; return }
                    _ = try OpenSSHPrivateKey.parse(pem)
                    if profile.keyID != nil {
                        // 改为该服务器专属私钥（会同步“不再引用密钥库”这一配置变化）。
                        profile.keyID = nil
                        try store.save(profile, secret: pem + "\n")
                    } else {
                        try KeychainStore.save(pem + "\n", for: hostID, kind: .privateKey)
                    }
                }
            }
            secret = ""
            dismiss()
            onSaved()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
