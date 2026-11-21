import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

public enum MoshError: Error, LocalizedError, Equatable {
    case serverNotInstalled
    case serverStartFailed(String)
    case udpUnreachable(host: String, port: Int)
    case protocolMismatch

    public static let installHint = """
    Debian / Ubuntu：sudo apt install mosh
    RHEL / CentOS / Fedora：sudo dnf install mosh（或 sudo yum install mosh，需 EPEL）
    Alpine：sudo apk add mosh
    Arch：sudo pacman -S mosh
    macOS：brew install mosh
    """

    public static let firewallHint = """
    需要放行服务器的 UDP 60000–61000 端口：
    ufw：sudo ufw allow 60000:61000/udp
    firewalld：sudo firewall-cmd --permanent --add-port=60000-61000/udp && sudo firewall-cmd --reload
    iptables：sudo iptables -A INPUT -p udp --dport 60000:61000 -j ACCEPT
    云服务器还需在安全组 / 防火墙规则中放行该 UDP 端口范围。
    """

    public var errorDescription: String? {
        switch self {
        case .serverNotInstalled:
            return "服务器未安装 mosh-server（command -v mosh-server 未找到）。安装方法：\n\(Self.installHint)"
        case .serverStartFailed(let output):
            return "mosh-server 启动失败：\n\(output)"
        case .udpUnreachable(let host, let port):
            return "mosh-server 已在 \(host) 的 UDP \(port) 端口启动，但 5 秒内收不到 UDP 回包，端口可能被防火墙拦截。\n\(Self.firewallHint)"
        case .protocolMismatch:
            return "Mosh 协议版本不兼容，请升级服务器上的 mosh"
        }
    }
}

/// 一个 Mosh 终端会话：通过 SSH 启动 mosh-server，然后改走加密 UDP。
///
/// 网络切换（WiFi ↔ 蜂窝）、短暂断线、锁屏后，只要 mosh-server 仍在运行，调用 `resume()` 即可继续。
public final class MoshSession: @unchecked Sendable {
    public struct ConnectInfo: Equatable, Sendable {
        public var port: Int
        /// 会话密钥（Base64，22 字符）。只在内存中使用，不落盘。
        public var key: String
    }

    /// 测试钩子。
    public struct Options: Sendable {
        public var serverCommand = "mosh-server"
        public var udpPortOverride: Int?
        public var contactTimeout: TimeAmount = .seconds(5)
        public init() {}
    }

    private let transport: MoshTransport
    public let host: String
    public let port: Int

    private init(transport: MoshTransport, host: String, port: Int) {
        self.transport = transport
        self.host = host
        self.port = port
    }

    /// 检测 mosh-server → 通过 SSH 启动 → 连接 UDP 并等待首个回包。
    ///
    /// - Parameter command: 会话内要运行的命令（shell 命令字符串，例如 tmux 附加命令）；nil 为登录 shell。
    public static func start(
        over client: SSHClient,
        cols: Int,
        rows: Int,
        command: String? = nil,
        options: Options = Options(),
        onOutput: @escaping @Sendable ([UInt8]) -> Void,
        onEchoAck: @escaping @Sendable (UInt64) -> Void = { _ in },
        onClose: @escaping @Sendable (Error?) -> Void
    ) async throws -> MoshSession {
        let detect = try await client.exec(ShellQuote.script("command -v \(options.serverCommand)"))
        guard detect.succeeded, !detect.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MoshError.serverNotInstalled
        }
        let info = try await launchServer(client: client, command: command, options: options)

        guard let remoteIP = client.remoteAddress?.ipAddress,
              let key = decodeKey(info.key) else {
            throw MoshError.serverStartFailed("无法解析服务器地址或会话密钥")
        }
        let udpPort = options.udpPortOverride ?? info.port
        let target = try SocketAddress(ipAddress: remoteIP, port: udpPort)

        let contact = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: Void.self)
        let closedEarly = NIOLockedValueBox(false)
        let transport = MoshTransport(key: key, target: target, callbacks: .init(
            hostBytes: onOutput,
            echoAck: onEchoAck,
            firstContact: { contact.succeed(()) },
            closed: { error in
                closedEarly.withLockedValue { $0 = true }
                contact.fail(error ?? MoshError.serverStartFailed("会话已结束"))
                onClose(error)
            }
        ))
        let timer = contact.futureResult.eventLoop.scheduleTask(in: options.contactTimeout) {
            contact.fail(MoshError.udpUnreachable(host: remoteIP, port: udpPort))
        }
        transport.start(cols: max(cols, 1), rows: max(rows, 1))
        do {
            try await contact.futureResult.get()
            timer.cancel()
        } catch {
            timer.cancel()
            if !closedEarly.withLockedValue({ $0 }) { transport.shutdown() }
            throw error
        }
        return MoshSession(transport: transport, host: remoteIP, port: udpPort)
    }

    /// 发送按键；completion 返回该按键所属的客户端状态号（用于本地回显确认）。
    public func send(_ bytes: [UInt8], completion: (@Sendable (UInt64) -> Void)? = nil) {
        transport.send(bytes, completion: completion)
    }

    public func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        transport.resize(cols: cols, rows: rows)
    }

    /// 回到前台或网络切换后调用。
    public func resume() {
        transport.resume()
    }

    /// 结束会话（通知服务器退出）。
    public func close() {
        transport.shutdown()
    }

    /// 平滑往返时延（毫秒）。
    public var roundTripTime: Double { transport.smoothedRTT }

    // MARK: - Bootstrap

    static func launchServer(client: SSHClient, command: String?, options: Options) async throws -> ConnectInfo {
        // mosh-server 自身需要 UTF-8 locale；先试 C.UTF-8（Linux 普遍提供），再试 en_US.UTF-8（macOS 等）。
        var lastOutput = ""
        for locale in ["C.UTF-8", "en_US.UTF-8"] {
            var line = "\(options.serverCommand) new -s -c 256 -l LANG=\(locale) -l LC_ALL=\(locale)"
            if let command { line += " -- \(command)" }
            let result = try await client.exec(
                ShellQuote.script("LANG=\(locale) LC_ALL=\(locale) \(line)"), timeout: .seconds(20)
            )
            let output = result.stdout + result.stderr
            if let info = parseConnectLine(output) { return info }
            lastOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !(output.contains("locale") || output.contains("UTF-8")) { break }
        }
        throw MoshError.serverStartFailed(lastOutput.isEmpty ? "没有输出 MOSH CONNECT" : lastOutput)
    }

    /// 解析 `MOSH CONNECT <port> <key>`。
    static func parseConnectLine(_ output: String) -> ConnectInfo? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            guard parts.count >= 4, parts[0] == "MOSH", parts[1] == "CONNECT",
                  let port = Int(parts[2]), (1...65535).contains(port), parts[3].count == 22
            else { continue }
            return ConnectInfo(port: port, key: String(parts[3]))
        }
        return nil
    }

    /// Mosh 密钥：22 个 Base64 字符（省略了 "==" 填充）→ 16 字节。
    static func decodeKey(_ text: String) -> [UInt8]? {
        guard text.count == 22, let data = Data(base64Encoded: text + "=="), data.count == 16 else { return nil }
        return Array(data)
    }
}
