import Foundation

/// 服务器上的一个 tmux 会话。
public struct TmuxSession: Identifiable, Hashable, Sendable {
    public var name: String
    public var createdAt: Date
    /// 当前附加的客户端数量；大于 0 显示 “In use”。
    public var attachedClients: Int
    public var windows: Int

    public var id: String { name }
    public var isInUse: Bool { attachedClients > 0 }
}

public enum TmuxError: Error, LocalizedError, Equatable {
    case notInstalled
    case invalidName(String)
    case commandFailed(String)

    /// 服务器未安装 tmux 时给用户的安装说明。
    public static let installHint = """
    Debian / Ubuntu：sudo apt install tmux
    RHEL / CentOS / Fedora：sudo dnf install tmux（或 sudo yum install tmux）
    Alpine：sudo apk add tmux
    Arch：sudo pacman -S tmux
    macOS：brew install tmux
    """

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "服务器未安装 tmux（command -v tmux 未找到）。安装方法：\n\(Self.installHint)"
        case .invalidName(let reason):
            return reason
        case .commandFailed(let message):
            return "tmux 命令失败：\(message)"
        }
    }
}

/// tmux 命令构造与输出解析（纯函数，可单元测试）。
public struct TmuxCommands: Sendable {
    /// 可选的独立 socket（`tmux -L`），仅测试使用，App 使用默认 socket 以便与用户平时的会话互通。
    public var socketName: String?

    public init(socketName: String? = nil) {
        self.socketName = socketName
    }

    /// 字段分隔符。通过非交互 SSH 执行时 tmux 会把制表符等控制字符替换成 `_`，
    /// 而 tmux 本身禁止会话名包含 `:`，其余字段都是数字，所以 `:` 不会产生歧义。
    static let separator = ":"

    /// `-u`：强制按 UTF-8 输出。非交互 SSH 会话常无 UTF-8 locale，否则中文等会话名会被替换成 `_`。
    private var tmux: String {
        socketName.map { "tmux -u -L \(ShellQuote.quote($0))" } ?? "tmux -u"
    }

    public var detect: String {
        ShellQuote.script("command -v tmux")
    }

    public var listSessions: String {
        let format = ["#{session_name}", "#{session_created}", "#{session_attached}", "#{session_windows}"]
            .joined(separator: Self.separator)
        return ShellQuote.script("\(tmux) list-sessions -F \(ShellQuote.quote(format))")
    }

    public func newDetached(_ name: String) throws -> String {
        try Self.validate(name)
        return ShellQuote.script("\(tmux) new-session -d -s \(ShellQuote.quote(name))")
    }

    public func rename(_ name: String, to newName: String) throws -> String {
        try Self.validate(newName)
        return ShellQuote.script("\(tmux) rename-session -t \(ShellQuote.quote("=" + name)) \(ShellQuote.quote(newName))")
    }

    public func kill(_ name: String) -> String {
        ShellQuote.script("\(tmux) kill-session -t \(ShellQuote.quote("=" + name))")
    }

    /// 交互式附加（PTY exec 用）：会话存在则附加，否则创建。
    public func attachOrCreate(_ name: String) -> String {
        ShellQuote.script("exec \(tmux) new-session -A -s \(ShellQuote.quote(name))")
    }

    /// 抓取指定会话当前活动面板的滚动缓冲历史（默认最近 5000 行，-J 合并自动折行并去掉行尾填充空格）。
    public func capturePane(_ name: String, historyLines: Int = 5000) -> String {
        let start = -max(1, historyLines)
        return ShellQuote.script("\(tmux) capture-pane -p -J -t \(ShellQuote.quote("=" + name)) -S \(start)")
    }

    /// App 默认实例的便捷入口。
    public static func attachOrCreate(_ name: String) -> String {
        TmuxCommands().attachOrCreate(name)
    }

    /// 会话名规则：tmux 不允许 `:` 与 `.`；另外拒绝空白名、控制字符和以 `-` 开头（避免被当作选项）。
    public static func validate(_ name: String) throws {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { throw TmuxError.invalidName("会话名不能为空") }
        if name.count > 64 { throw TmuxError.invalidName("会话名不能超过 64 个字符") }
        if name.contains(":") || name.contains(".") { throw TmuxError.invalidName("会话名不能包含 “:” 或 “.”") }
        if name.hasPrefix("-") { throw TmuxError.invalidName("会话名不能以 “-” 开头") }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw TmuxError.invalidName("会话名不能包含控制字符")
        }
    }

    /// 解析 list-sessions 输出。
    public static func parseSessions(_ output: String) -> [TmuxSession] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.components(separatedBy: separator)
            guard fields.count == 4, let created = TimeInterval(fields[1]) else { return nil }
            return TmuxSession(
                name: fields[0],
                createdAt: Date(timeIntervalSince1970: created),
                attachedClients: Int(fields[2]) ?? 0,
                windows: Int(fields[3]) ?? 0
            )
        }
    }

    /// list-sessions 在没有 tmux 服务器运行时以非零状态退出，这种情况视为“没有会话”。
    static func isNoServerError(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return text.contains("no server running") || text.contains("error connecting to")
            || text.contains("no sessions")
    }
}

/// 通过 SSH exec 管理服务器上的 tmux 会话。
public struct TmuxManager: Sendable {
    public let client: SSHClient
    public var commands: TmuxCommands

    public init(client: SSHClient, commands: TmuxCommands = TmuxCommands()) {
        self.client = client
        self.commands = commands
    }

    /// 检测服务器是否安装了 tmux；未安装抛出 `.notInstalled`（含安装方法）。
    public func ensureInstalled() async throws {
        let result = try await client.exec(commands.detect)
        guard result.succeeded, !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TmuxError.notInstalled
        }
    }

    public func list() async throws -> [TmuxSession] {
        let result = try await client.exec(commands.listSessions)
        if result.succeeded { return TmuxCommands.parseSessions(result.stdout) }
        if TmuxCommands.isNoServerError(result.stderr) { return [] }
        throw TmuxError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func create(_ name: String) async throws {
        try await run(try commands.newDetached(name))
    }

    public func rename(_ name: String, to newName: String) async throws {
        try await run(try commands.rename(name, to: newName))
    }

    public func kill(_ name: String) async throws {
        try await run(commands.kill(name))
    }

    /// 抓取指定 tmux 会话的活动面板历史输出（纯文本）。
    public func capturePane(_ name: String, historyLines: Int = 5000) async throws -> String {
        let result = try await client.exec(commands.capturePane(name, historyLines: historyLines), timeout: .seconds(5))
        guard result.succeeded else {
            throw TmuxError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    private func run(_ command: String) async throws {
        let result = try await client.exec(command)
        guard result.succeeded else {
            throw TmuxError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// POSIX sh 引号与脚本包装。
public enum ShellQuote {
    /// 单引号包裹，内部的 ' 写成 '\''。
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 额外搜索路径：非交互 SSH 会话的 PATH 往往不含 Homebrew、/usr/local 等。
    static let extraPath = "/usr/local/bin:/opt/homebrew/bin:/opt/local/bin:/snap/bin:$HOME/.local/bin:$HOME/bin"

    /// 用 `sh -c` 执行，避免依赖用户登录 shell 的语法（fish 等），并补充 PATH。
    public static func script(_ body: String) -> String {
        "sh -c " + quote("PATH=\"$PATH:\(extraPath)\"; export PATH; \(body)")
    }
}
