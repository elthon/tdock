import Combine
import Foundation
import SwiftUI
import TDockCore

/// 全局会话管理：每台主机一条共享的 SSH 连接（HostConnection）+ 所有打开的终端标签。
/// 终端不随页面销毁，返回列表后继续保持，可从主机详情页回到它。
@MainActor
final class SessionManager: ObservableObject {
    struct HostKeyPrompt: Identifiable {
        let id = UUID()
        let host: String
        let port: Int
        let key: HostKeyInfo
    }

    @Published private(set) var terminals: [TerminalSession] = []
    @Published private(set) var hostKeyPrompt: HostKeyPrompt?

    let store: ServerStore
    let settings: AppSettings
    private let knownHosts: KnownHostsStore
    private var connections: [UUID: HostConnection] = [:]
    /// 每台主机的标签编号（只增不减，关闭标签后编号不重复）。
    private var shellCounters: [UUID: Int] = [:]
    private var hostKeyContinuation: CheckedContinuation<Bool, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(store: ServerStore, settings: AppSettings, knownHosts: KnownHostsStore = .shared) {
        self.store = store
        self.settings = settings
        self.knownHosts = knownHosts
        // 主题/字号变化实时作用到所有打开的终端。
        settings.appearanceChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyAppearance() }
            .store(in: &cancellables)
        settings.$shortcutLayout
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] layout in self?.terminals.forEach { $0.updateShortcutBar(layout) } }
            .store(in: &cancellables)
        settings.$snippets
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snippets in self?.terminals.forEach { $0.updateSnippets(snippets) } }
            .store(in: &cancellables)
    }

    func profile(_ id: UUID) -> ServerProfile? {
        store.servers.first { $0.id == id }
    }

    // MARK: - Connections

    func connection(for hostID: UUID) -> HostConnection {
        if let existing = connections[hostID] { return existing }
        let connection = HostConnection(hostID: hostID, manager: self)
        connections[hostID] = connection
        return connection
    }

    var allConnections: [HostConnection] { Array(connections.values) }

    /// 建立新的 SSH 连接（由 HostConnection 调用；同一主机并发请求会被合并）。
    func makeClient(for profile: ServerProfile, credential override: SSHCredential? = nil) async throws -> SSHClient {
        let credential = try override ?? CredentialProvider.credential(for: profile)
        let host = profile.host.trimmingCharacters(in: .whitespaces)
        let port = profile.port
        return try await SSHClient.connect(
            host: host,
            port: port,
            username: profile.username.trimmingCharacters(in: .whitespaces),
            credential: credential
        ) { [weak self] key in
            guard let self else { throw CancellationError() }
            try await self.validateHostKey(key, host: host, port: port)
        }
    }

    // MARK: - Terminals

    func terminals(for hostID: UUID) -> [TerminalSession] {
        terminals.filter { $0.hostID == hostID }
    }

    @discardableResult
    func openTerminal(hostID: UUID, kind: TerminalSession.Kind = .shell) -> TerminalSession {
        // tmux 会话已在某个标签中打开时直接切换过去，避免同一会话开两个标签。
        if case .tmux = kind, let existing = terminals.first(where: { $0.hostID == hostID && $0.kind == kind }) {
            return existing
        }
        let index = (shellCounters[hostID] ?? 0) + 1
        shellCounters[hostID] = index
        let session = TerminalSession(hostID: hostID, kind: kind, index: index, manager: self)
        terminals.append(session)
        session.start()
        return session
    }

    /// 最近使用的终端（服务器列表“恢复最近终端”）。
    func mostRecentTerminal(hostID: UUID) -> TerminalSession? {
        terminals(for: hostID).max { $0.lastActiveAt < $1.lastActiveAt }
    }

    /// 有打开终端的主机（按服务器列表顺序），用于跨主机切换。
    var activeHostIDs: [UUID] {
        let ids = Set(terminals.map(\.hostID))
        return store.servers.map(\.id).filter(ids.contains)
    }

    /// 补填凭据 / 更新指纹之后：重连该主机所有因此失败的标签。
    func retryFailedTerminals(hostID: UUID) {
        for session in terminals(for: hostID) where session.issue != nil {
            session.restart()
        }
    }

    /// 主机重装后指纹变化：用户二次确认后用新指纹替换记录，并重连。
    func replaceTrustedHostKey(host: String, port: Int, with value: String, hostID: UUID) {
        knownHosts.replace(host: host, port: port, value: value)
        retryFailedTerminals(hostID: hostID)
    }

    func close(_ session: TerminalSession) {
        session.shutdown()
        terminals.removeAll { $0 === session }
        // 该主机没有任何终端和转发时，断开共享连接以节省资源。
        if let connection = connections[session.hostID], terminals(for: session.hostID).isEmpty, !connection.hasActiveForwards {
            connection.disconnect()
        }
    }

    func closeAll(hostID: UUID) {
        terminals(for: hostID).forEach(close)
    }

    func disconnectImportedProfiles(_ ids: Set<UUID>) {
        for id in ids {
            closeAll(hostID: id)
            connections[id]?.disconnect()
            connections[id] = nil
        }
    }

    func tmuxSessionRenamed(hostID: UUID, from oldName: String, to newName: String) {
        terminals(for: hostID).filter { $0.kind == .tmux(oldName) }.forEach { $0.renameTmux(to: newName) }
    }

    /// 应用设置（主题/字体）变化时调用。
    func applyAppearance() {
        terminals.forEach { $0.applyAppearance() }
    }

    // MARK: - Host key (TOFU)

    private func validateHostKey(_ key: HostKeyInfo, host: String, port: Int) async throws {
        switch knownHosts.verdict(host: host, port: port, key: key) {
        case .trusted:
            return
        case .mismatch(let expected):
            throw SSHSessionError.hostKeyMismatch(expected: expected, actual: "\(key.keyType) \(key.fingerprint)")
        case .unknown:
            // 一次只显示一个确认框；若已有确认在进行，先等它结束。
            while hostKeyContinuation != nil {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if knownHosts.verdict(host: host, port: port, key: key) == .trusted { return }
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

/// 一台主机的共享 SSH 连接。多个终端标签、SFTP、端口转发、tmux 管理命令都复用它。
@MainActor
final class HostConnection: ObservableObject {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    enum ForwardState: Equatable {
        case starting
        case running(connections: Int)
        case failed(String)
    }

    let hostID: UUID
    @Published private(set) var status: Status = .disconnected
    /// 端口转发规则 ID → 状态；不在字典中表示未启用。
    @Published private(set) var forwardStates: [UUID: ForwardState] = [:]
    private var forwarders: [UUID: LocalPortForwarder] = [:]

    private weak var manager: SessionManager?
    private var sshClient: SSHClient?
    private var pending: Task<SSHClient, Error>?

    init(hostID: UUID, manager: SessionManager) {
        self.hostID = hostID
        self.manager = manager
    }

    var hasActiveForwards: Bool { !forwarders.isEmpty }

    // MARK: - Port forwarding

    func startForward(_ rule: PortForwardRule) {
        guard forwarders[rule.id] == nil, forwardStates[rule.id] != .starting else { return }
        forwardStates[rule.id] = .starting
        Task {
            do {
                let client = try await self.client()
                let forwarder = try await LocalPortForwarder.start(
                    client: client,
                    localPort: rule.localPort,
                    remoteHost: rule.remoteHost.trimmingCharacters(in: .whitespaces),
                    remotePort: rule.remotePort
                ) { [weak self] count in
                    Task { @MainActor in
                        if self?.forwarders[rule.id] != nil { self?.forwardStates[rule.id] = .running(connections: count) }
                    }
                }
                guard forwardStates[rule.id] == .starting else { return forwarder.stop() } // 启动期间被用户关闭
                forwarders[rule.id] = forwarder
                forwardStates[rule.id] = .running(connections: 0)
                forwarder.onStop { [weak self] in
                    Task { @MainActor in self?.forwardStopped(rule.id, forwarder) }
                }
            } catch {
                forwardStates[rule.id] = .failed(error.localizedDescription)
            }
        }
    }

    func stopForward(_ ruleID: UUID) {
        forwarders.removeValue(forKey: ruleID)?.stop()
        forwardStates[ruleID] = nil
    }

    private func forwardStopped(_ ruleID: UUID, _ forwarder: LocalPortForwarder) {
        guard forwarders[ruleID] === forwarder else { return }
        forwarders[ruleID] = nil
        forwardStates[ruleID] = .failed("SSH 连接已断开，转发已停止")
    }

    /// 返回可用的连接；未连接时建立连接。同时到来的请求共享同一次连接过程。
    func client() async throws -> SSHClient {
        if let sshClient, sshClient.isActive { return sshClient }
        if let pending { return try await pending.value }
        guard let manager, let profile = manager.profile(hostID) else { throw SSHSessionError.connectionClosed }

        status = .connecting
        let task = Task { try await manager.makeClient(for: profile) }
        pending = task
        defer { pending = nil }
        do {
            let client = try await task.value
            self.sshClient = client
            status = .connected
            client.onDisconnect { [weak self] error in
                Task { @MainActor in self?.clientDidClose(client, error: error) }
            }
            return client
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    var isConnected: Bool { sshClient?.isActive == true }

    func disconnect() {
        forwarders.values.forEach { $0.stop() }
        forwarders = [:]
        forwardStates = [:]
        sshClient?.close()
        sshClient = nil
        status = .disconnected
    }

    private func clientDidClose(_ closed: SSHClient, error: Error?) {
        guard sshClient === closed else { return }
        sshClient = nil
        status = error.map { .failed($0.localizedDescription) } ?? .disconnected
    }
}
