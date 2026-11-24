import Foundation
import XCTest
@testable import TDockCore

/// 使用独立 socket（tmux -L），不影响用户已有的 tmux 会话。
final class TmuxIntegrationTests: XCTestCase {
    private let socket = "tdock-it-\(UUID().uuidString.prefix(8))"

    func testSessionLifecycle() async throws {
        let config = try IntegrationConfig.load()
        let client = try await config.connect()
        defer { client.close() }
        let tmux = TmuxManager(client: client, commands: TmuxCommands(socketName: socket))
        do {
            try await tmux.ensureInstalled()
        } catch TmuxError.notInstalled {
            throw XCTSkip("测试服务器未安装 tmux")
        }
        defer { Task { _ = try? await client.exec(ShellQuote.script("tmux -L \(self.socket) kill-server")) } }

        let initial = try await tmux.list()
        XCTAssertEqual(initial, [], "没有 tmux 服务器时应返回空列表")

        try await tmux.create("alpha")
        try await tmux.create("beta 二")
        var sessions = try await tmux.list()
        XCTAssertEqual(Set(sessions.map(\.name)), ["alpha", "beta 二"], "含空格与中文的会话名应原样返回")
        XCTAssertTrue(sessions.allSatisfy { !$0.isInUse })

        // 交互式附加后显示为 In use
        let out = OutputCollector()
        let attached = try await client.openShell(
            cols: 80, rows: 24, command: TmuxCommands(socketName: socket).attachOrCreate("alpha"),
            onOutput: { out.append($0) }, onClose: { _ in }
        )
        try await Task.sleep(nanoseconds: 800_000_000)
        sessions = try await tmux.list()
        XCTAssertEqual(sessions.first { $0.name == "alpha" }?.isInUse, true)
        attached.send(Array("echo TMUX_$((6*7))\r".utf8))
        try await out.waitFor("TMUX_42")
        attached.close()

        // capture-pane 的 -t 是面板目标：精确会话名必须写成 "=name:"，否则 tmux 报 can't find pane。
        let captured = try await tmux.capturePane("alpha")
        XCTAssertTrue(captured.contains("TMUX_42"), "应抓到会话历史输出：\(captured)")
        do {
            _ = try await tmux.capturePane("alp")
            XCTFail("会话名前缀不应匹配到 alpha")
        } catch TmuxError.commandFailed {}

        try await tmux.rename("beta 二", to: "gamma")
        try await tmux.kill("alpha")
        try await Task.sleep(nanoseconds: 300_000_000)
        sessions = try await tmux.list()
        XCTAssertEqual(sessions.map(\.name), ["gamma"])

        do {
            try await tmux.create("gamma")
            XCTFail("重名应失败")
        } catch TmuxError.commandFailed(let message) {
            XCTAssertTrue(message.contains("duplicate"), message)
        }
    }

    func testMissingTmuxIsReported() async throws {
        let config = try IntegrationConfig.load()
        let client = try await config.connect()
        defer { client.close() }
        // 用一个不存在的命令名模拟未安装。
        var commands = TmuxCommands()
        commands.socketName = nil
        let result = try await client.exec(ShellQuote.script("command -v tdock-no-such-tmux"))
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(TmuxError.notInstalled.localizedDescription.contains("sudo apt install tmux"))
    }
}
