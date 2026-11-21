import SwiftTerm
import SwiftUI
import TDockCore

/// 一个终端会话：把 SwiftTerm 的 TerminalView 和 SSHShellSession 连接起来，
/// 并负责凭据读取、主机密钥 TOFU 确认和会话状态。
@MainActor
final class SessionController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        /// message 为 nil 表示远端正常退出。
        case ended(message: String?)
    }

    struct HostKeyPrompt: Identifiable {
        let id = UUID()
        let host: String
        let port: Int
        let key: HostKeyInfo
    }

    struct MissingCredential: LocalizedError {
        var errorDescription: String? { "未找到已保存的密码/私钥，请编辑该服务器重新填写" }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hostKeyPrompt: HostKeyPrompt?

    let profile: ServerProfile
    let terminalView: TerminalView

    private var session: SSHShellSession?
    private var hostKeyContinuation: CheckedContinuation<Bool, Never>?
    private let knownHosts: KnownHostsStore

    init(profile: ServerProfile, knownHosts: KnownHostsStore = .shared) {
        self.profile = profile
        self.knownHosts = knownHosts
        terminalView = TerminalView(frame: .zero)
        terminalView.nativeBackgroundColor = .black
        terminalView.nativeForegroundColor = .white
        terminalView.terminalDelegate = self
    }

    // MARK: - Connect / disconnect

    func connect() {
        guard phase != .connecting, phase != .connected else { return }
        phase = .connecting

        let credential: SSHShellSession.Credential
        do {
            credential = try loadCredential()
        } catch {
            phase = .ended(message: error.localizedDescription)
            return
        }

        let host = profile.host.trimmingCharacters(in: .whitespaces)
        let port = profile.port
        let dims = terminalView.terminalDimensions
        let session = SSHShellSession(
            host: host,
            port: port,
            username: profile.username.trimmingCharacters(in: .whitespaces),
            credential: credential,
            initialSize: (cols: dims.cols > 0 ? dims.cols : 80, rows: dims.rows > 0 ? dims.rows : 24),
            hostKeyValidator: { [weak self] key in
                guard let self else { throw CancellationError() }
                try await self.validateHostKey(key, host: host, port: port)
            }
        )
        let sessionID = ObjectIdentifier(session)
        let feeder = terminalView.feedSender // 线程安全，可直接在 NIO 线程调用
        session.onOutput = { bytes in feeder.feed(byteArray: bytes[...]) }
        session.onClose = { [weak self] error in
            Task { @MainActor in self?.sessionEnded(sessionID, error: error) }
        }
        self.session = session

        Task {
            do {
                try await session.start()
                guard self.session === session else { return }
                phase = .connected
                // 连接期间布局可能已变化（旋转、键盘），同步一次尺寸。
                let dims = terminalView.terminalDimensions
                session.resize(cols: dims.cols, rows: dims.rows)
                _ = terminalView.becomeFirstResponder()
            } catch {
                guard self.session === session else { return }
                self.session = nil
                phase = .ended(message: error.localizedDescription)
            }
        }
    }

    func disconnect() {
        answerHostKeyPrompt(trust: false)
        let session = self.session
        self.session = nil
        session?.close()
        phase = .idle
    }

    private func sessionEnded(_ id: ObjectIdentifier, error: Error?) {
        guard let session, ObjectIdentifier(session) == id else { return }
        self.session = nil
        phase = .ended(message: error?.localizedDescription)
        _ = terminalView.resignFirstResponder()
    }

    private func loadCredential() throws -> SSHShellSession.Credential {
        switch profile.authMethod {
        case .password:
            guard let password = try KeychainStore.load(for: profile.id, kind: .password) else {
                throw MissingCredential()
            }
            return .password(password)
        case .privateKey:
            guard let pem = try KeychainStore.load(for: profile.id, kind: .privateKey) else {
                throw MissingCredential()
            }
            return .privateKey(try OpenSSHPrivateKey.parse(pem))
        }
    }

    // MARK: - Host key (TOFU)

    private func validateHostKey(_ key: HostKeyInfo, host: String, port: Int) async throws {
        switch knownHosts.verdict(host: host, port: port, key: key) {
        case .trusted:
            return
        case .mismatch(let expected):
            throw SSHSessionError.hostKeyMismatch(expected: expected, actual: "\(key.keyType) \(key.fingerprint)")
        case .unknown:
            answerHostKeyPrompt(trust: false) // 理论上不会有未完成的旧提示，保险起见
            let trusted = await withCheckedContinuation { continuation in
                hostKeyContinuation = continuation
                hostKeyPrompt = HostKeyPrompt(host: host, port: port, key: key)
            }
            guard trusted else { throw SSHSessionError.hostKeyRejected }
            knownHosts.trust(host: host, port: port, key: key)
        }
    }

    func answerHostKeyPrompt(trust: Bool) {
        hostKeyPrompt = nil
        let continuation = hostKeyContinuation
        hostKeyContinuation = nil
        continuation?.resume(returning: trust)
    }
}

// MARK: - TerminalViewDelegate

extension SessionController: TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session?.send(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
