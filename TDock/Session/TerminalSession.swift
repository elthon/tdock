import SwiftTerm
import SwiftUI
import TDockCore

/// 终端数据通道的抽象：SSH shell 通道或 Mosh 会话。只在主线程调用。
@MainActor
protocol TerminalTransport: AnyObject {
    func send(_ bytes: [UInt8])
    func resize(cols: Int, rows: Int)
    func close()
}

/// 可在回到前台/网络切换后自行恢复的传输（Mosh）。
@MainActor
protocol ResumableTransport: TerminalTransport {
    func resume()
}

extension SSHShellChannel: TerminalTransport {}

/// 一个终端标签：一个 SwiftTerm 视图 + 一条传输通道。
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum Kind: Hashable {
        case shell
        case tmux(String)

        var tmuxName: String? {
            if case .tmux(let name) = self { return name }
            return nil
        }
    }

    enum Phase: Equatable {
        case connecting
        case connected
        /// message 为 nil 表示远端正常退出。
        case ended(message: String?)
    }

    /// 滚动缓冲上限（行）。
    static let scrollbackLines = 5000

    let id = UUID()
    let hostID: UUID
    let createdAt = Date()
    @Published private(set) var kind: Kind
    @Published private(set) var phase: Phase = .connecting
    /// 远端程序通过 OSC 设置的标题（例如 shell 提示的 user@host:~）。
    @Published private(set) var remoteTitle = ""
    let terminalView: TerminalView

    private let index: Int
    private weak var manager: SessionManager?
    private var transport: TerminalTransport?
    private var shortcutBar: ShortcutBar?
    private var generation = 0
    /// 因连接丢失而结束、需要自动重连。
    private var needsReconnect = false
    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 3

    init(hostID: UUID, kind: Kind, index: Int, manager: SessionManager) {
        self.hostID = hostID
        self.kind = kind
        self.index = index
        self.manager = manager
        terminalView = TerminalView(
            frame: .zero,
            font: nil,
            options: TerminalOptions(scrollback: Self.scrollbackLines)
        )
        terminalView.terminalDelegate = self
        // 自定义快捷栏替换 SwiftTerm 默认的按键栏。
        let bar = ShortcutBar(terminalView: terminalView, layout: manager.settings.shortcutLayout)
        terminalView.inputAccessoryView = bar
        shortcutBar = bar
        applyAppearance()
    }

    func updateShortcutBar(_ layout: ShortcutLayout) {
        shortcutBar?.update(layout: layout)
    }

    var title: String {
        switch kind {
        case .shell: return "Shell \(index)"
        case .tmux(let name): return name
        }
    }

    var subtitle: String {
        switch kind {
        case .shell: return remoteTitle.isEmpty ? "shell" : remoteTitle
        case .tmux(let name): return "tmux · \(name)"
        }
    }

    var profile: ServerProfile? { manager?.profile(hostID) }

    // MARK: - Lifecycle

    func start() {
        guard let manager else { return }
        transport?.close()
        transport = nil
        generation += 1
        let generation = self.generation
        phase = .connecting

        let dims = terminalView.terminalDimensions
        let cols = dims.cols > 0 ? dims.cols : 80
        let rows = dims.rows > 0 ? dims.rows : 24
        let feeder = terminalView.feedSender // 线程安全：网络线程直接送数据，不经主线程
        let command = kind.tmuxName.map { TmuxCommands.attachOrCreate($0) }

        let useMosh = profile?.transport == .mosh

        Task {
            do {
                let client = try await manager.connection(for: hostID).client()
                if kind.tmuxName != nil {
                    // 未安装 tmux 时给出明确原因与安装方法，而不是让 shell 报 “tmux: not found”。
                    try await TmuxManager(client: client).ensureInstalled()
                }
                if useMosh {
                    try await startMosh(client: client, cols: cols, rows: rows, command: command, generation: generation)
                } else {
                    let channel = try await client.openShell(
                        cols: cols, rows: rows, command: command,
                        onOutput: { feeder.feed(byteArray: $0[...]) },
                        onClose: { [weak self] reason in
                            Task { @MainActor in self?.transportClosed(generation, reason.error, exitStatus: reason.exitStatus) }
                        }
                    )
                    guard self.generation == generation else { return channel.close() }
                    attach(channel)
                }
            } catch {
                guard self.generation == generation else { return }
                phase = .ended(message: error.localizedDescription)
                if needsReconnect { scheduleReconnect() }
            }
        }
    }

    /// Mosh：经 SSH 启动 mosh-server，之后走 UDP（SSH 连接断开不影响会话）。
    private func startMosh(client: SSHClient, cols: Int, rows: Int, command: String?, generation: Int) async throws {
        let feeder = terminalView.feedSender
        let bridge = MoshCallbackBridge()
        let session = try await MoshSession.start(
            over: client, cols: cols, rows: rows, command: command,
            onOutput: { bytes in
                feeder.feed(byteArray: bytes[...]) // 直接送入终端，不经主线程
                Task { @MainActor in bridge.transport?.hostOutput(bytes) }
            },
            onEchoAck: { num in Task { @MainActor in bridge.transport?.echoAcked(num) } },
            onClose: { [weak self] error in
                Task { @MainActor in self?.moshClosed(generation, error) }
            }
        )
        guard self.generation == generation else { return session.close() }
        let transport = MoshTerminalTransport(session: session, terminalView: terminalView)
        bridge.transport = transport
        attach(transport)
    }

    private func moshClosed(_ generation: Int, _ error: Error?) {
        guard self.generation == generation else { return }
        transport = nil
        // mosh-server 结束（远端退出或出错）：Mosh 本身已处理断线，这里不自动重连。
        phase = .ended(message: error?.localizedDescription)
    }

    private func attach(_ transport: TerminalTransport) {
        self.transport = transport
        phase = .connected
        needsReconnect = false
        reconnectAttempts = 0
        // 连接期间布局可能已变化（旋转、键盘），同步一次尺寸。
        let dims = terminalView.terminalDimensions
        transport.resize(cols: dims.cols, rows: dims.rows)
        _ = terminalView.becomeFirstResponder()
    }

    private func transportClosed(_ generation: Int, _ error: Error?, exitStatus: Int?) {
        guard self.generation == generation else { return }
        transport = nil
        let connectionLost = manager?.connection(for: hostID).isConnected == false
        if connectionLost {
            // 网络/连接问题：自动重连（tmux 会话可无损恢复）。
            phase = .ended(message: "连接已断开")
            needsReconnect = true
            if UIApplication.shared.applicationState == .active { scheduleReconnect() }
        } else if let error {
            phase = .ended(message: error.localizedDescription)
        } else {
            phase = .ended(message: nil) // 远端正常退出（例如执行了 exit），不自动重连
        }
    }

    /// 自动重连，指数退避：1s、2s、4s。
    private func scheduleReconnect() {
        guard needsReconnect, reconnectAttempts < Self.maxReconnectAttempts else { return }
        let delay = UInt64(1 << reconnectAttempts) * 1_000_000_000
        reconnectAttempts += 1
        let generation = self.generation
        Task {
            try? await Task.sleep(nanoseconds: delay)
            guard self.generation == generation, needsReconnect else { return }
            if kind.tmuxName == nil {
                terminalView.feed(text: "\r\n\u{1b}[33m[tdock] 连接已断开，正在重新连接（将打开新的 shell）…\u{1b}[0m\r\n")
            }
            start()
        }
    }

    /// 回到前台时由 BackgroundKeeper 调用。
    func resumeAfterForeground() {
        if let resumable = transport as? ResumableTransport {
            resumable.resume()
        } else if needsReconnect {
            reconnectAttempts = 0
            scheduleReconnect()
        }
    }

    /// tmux 会话在别处被重命名后更新标签（不重连：已附加的客户端会自动跟随新名称）。
    func renameTmux(to newName: String) {
        guard kind.tmuxName != nil else { return }
        kind = .tmux(newName)
    }

    /// 关闭标签时调用。
    func shutdown() {
        generation += 1
        transport?.close()
        transport = nil
    }

    var isAlive: Bool { transport != nil }

    // MARK: - Input

    func send(_ bytes: [UInt8]) {
        transport?.send(bytes)
    }

    // MARK: - Appearance

    func applyAppearance() {
        guard let settings = manager?.settings else { return }
        settings.apply(to: terminalView)
    }
}

// MARK: - TerminalViewDelegate

extension TerminalSession: TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        transport?.send(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        transport?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        remoteTitle = title
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return }
        UIApplication.shared.open(url)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// 在 Mosh 回调（网络线程）与主线程上的传输对象之间传递引用。
@MainActor
private final class MoshCallbackBridge {
    weak var transport: MoshTerminalTransport?
}
