import Foundation
import NIOConcurrencyHelpers
import NIOCore
import XCTest
@testable import TDockCore

/// 端到端：经 sshd 启动真实的 mosh-server，再走 UDP。
final class MoshIntegrationTests: XCTestCase {
    private func connect() async throws -> SSHClient {
        let config = try IntegrationConfig.load()
        let client = try await config.connect()
        let probe = try await client.exec(ShellQuote.script("command -v mosh-server"))
        guard probe.succeeded else {
            client.close()
            throw XCTSkip("测试服务器未安装 mosh-server")
        }
        return client
    }

    func testShellRoundTripAndRoaming() async throws {
        let client = try await connect()
        defer { client.close() }
        let out = OutputCollector()
        let echoAcks = NIOLockedValueBox<[UInt64]>([])
        let mosh = try await MoshSession.start(
            over: client, cols: 100, rows: 30,
            onOutput: { out.append($0) },
            onEchoAck: { n in echoAcks.withLockedValue { $0.append(n) } },
            onClose: { _ in }
        )
        defer { mosh.close() }

        // 按键逐个发送（不攒批），并检查终端尺寸已同步。
        for byte in Array("echo MOSH_$((6*7)); stty size\r".utf8) { mosh.send([byte]) }
        try await out.waitFor("MOSH_42")
        try await out.waitFor("30 100")
        XCTAssertGreaterThan(mosh.roundTripTime, 0)

        // 模拟网络切换：重建 UDP socket（源端口改变），会话应继续。
        mosh.resume()
        mosh.resize(cols: 90, rows: 20)
        try await Task.sleep(nanoseconds: 300_000_000)
        mosh.send(Array("echo AFTER_$((1+1)); stty size\r".utf8))
        try await out.waitFor("AFTER_2")
        try await out.waitFor("20 90")
        XCTAssertFalse(echoAcks.withLockedValue { $0 }.isEmpty, "应收到服务器的回显确认")
    }

    func testRemoteExitClosesSession() async throws {
        let client = try await connect()
        defer { client.close() }
        let closed = expectation(description: "closed")
        let reason = NIOLockedValueBox<String>("")
        let mosh = try await MoshSession.start(
            over: client, cols: 80, rows: 24,
            onOutput: { _ in },
            onClose: { error in
                reason.withLockedValue { $0 = error.map { "\($0)" } ?? "normal" }
                closed.fulfill()
            }
        )
        mosh.send(Array("exit\r".utf8))
        await fulfillment(of: [closed], timeout: 15)
        XCTAssertEqual(reason.withLockedValue { $0 }, "normal")
    }

    func testMoshWithTmux() async throws {
        let client = try await connect()
        defer { client.close() }
        guard (try? await client.exec(TmuxCommands().detect))?.succeeded == true else {
            throw XCTSkip("测试服务器未安装 tmux")
        }
        let socket = "tdock-it-mosh-\(UUID().uuidString.prefix(6))"
        defer { Task { _ = try? await client.exec(ShellQuote.script("tmux -L \(socket) kill-server")) } }
        let out = OutputCollector()
        let mosh = try await MoshSession.start(
            over: client, cols: 80, rows: 24,
            command: TmuxCommands(socketName: socket).attachOrCreate("mosh-tmux"),
            onOutput: { out.append($0) }, onClose: { _ in }
        )
        defer { mosh.close() }
        try await Task.sleep(nanoseconds: 500_000_000)
        mosh.send(Array("echo IN_TMUX_$((3+4))\r".utf8))
        try await out.waitFor("IN_TMUX_7")
        let sessions = try await TmuxManager(client: client, commands: TmuxCommands(socketName: socket)).list()
        XCTAssertEqual(sessions.first?.name, "mosh-tmux")
        XCTAssertEqual(sessions.first?.isInUse, true)
    }

    func testServerNotInstalled() async throws {
        let client = try await connect()
        defer { client.close() }
        var options = MoshSession.Options()
        options.serverCommand = "tdock-no-such-mosh-server"
        do {
            _ = try await MoshSession.start(over: client, cols: 80, rows: 24, options: options, onOutput: { _ in }, onClose: { _ in })
            XCTFail("应失败")
        } catch {
            XCTAssertEqual(error as? MoshError, .serverNotInstalled)
            XCTAssertTrue(error.localizedDescription.contains("sudo apt install mosh"))
        }
    }

    func testUDPUnreachable() async throws {
        let client = try await connect()
        defer { client.close() }
        var options = MoshSession.Options()
        options.udpPortOverride = 9 // 没有 mosh-server 监听的端口，模拟 UDP 被拦截
        options.contactTimeout = .seconds(2)
        do {
            _ = try await MoshSession.start(over: client, cols: 80, rows: 24, options: options, onOutput: { _ in }, onClose: { _ in })
            XCTFail("应失败")
        } catch {
            guard case .udpUnreachable(_, let port) = error as? MoshError else { return XCTFail("意外错误：\(error)") }
            XCTAssertEqual(port, 9)
            XCTAssertTrue(error.localizedDescription.contains("60000"))
        }
    }
}
