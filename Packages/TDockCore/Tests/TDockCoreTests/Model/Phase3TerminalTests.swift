import Foundation
import XCTest
@testable import TDockCore

final class Phase3TerminalTests: XCTestCase {
    func testModifierSingleTapIsOneShot() {
        var latch = ModifierLatch()
        latch.tap(at: 0)
        XCTAssertEqual(latch.state, .once)
        XCTAssertTrue(latch.isActive)
        latch.consumed()
        XCTAssertEqual(latch.state, .off)
    }

    func testModifierDoubleTapLocks() {
        var latch = ModifierLatch()
        latch.tap(at: 10)
        latch.tap(at: 10.2)
        XCTAssertEqual(latch.state, .locked)
        latch.consumed()
        latch.consumed()
        XCTAssertEqual(latch.state, .locked, "常驻锁定在按键后保持")
        latch.tap(at: 20)
        XCTAssertEqual(latch.state, .off, "常驻时再次点击解除")
    }

    func testModifierSlowSecondTapTurnsOff() {
        var latch = ModifierLatch()
        latch.tap(at: 0)
        latch.tap(at: ModifierLatch.doubleTapInterval + 0.1)
        XCTAssertEqual(latch.state, .off)
        // 关闭后重新开始计时
        latch.tap(at: 5)
        latch.tap(at: 5.1)
        XCTAssertEqual(latch.state, .locked)
        latch.reset()
        XCTAssertEqual(latch, ModifierLatch())
    }

    func testModifierConsumedBetweenTapsDoesNotLock() {
        var latch = ModifierLatch()
        latch.tap(at: 0)
        latch.consumed() // 单次已作用于一个按键
        latch.tap(at: 0.1)
        XCTAssertEqual(latch.state, .once, "消耗后的再次点击是新的单次，而不是双击")
    }

    func testSnippetBytes() {
        XCTAssertEqual(Snippet(command: "git status").bytes, Array("git status\r".utf8))
        XCTAssertEqual(Snippet(command: "tail -f ", sendReturn: false).bytes, Array("tail -f ".utf8))
        XCTAssertEqual(Snippet(command: "a\nb\r\nc").bytes, Array("a\rb\rc\r".utf8))
        XCTAssertEqual(Snippet(command: "ls\n").bytes, Array("ls\r".utf8), "已以换行结尾时不重复回车")
        XCTAssertEqual(Snippet(command: "echo 你好").bytes, Array("echo 你好\r".utf8))
    }

    func testSnippetDisplayAndValidation() {
        XCTAssertEqual(Snippet(title: " ", command: "docker ps").displayTitle, "docker ps")
        XCTAssertEqual(Snippet(title: "Claude", command: "claude").displayTitle, "Claude")
        XCTAssertNotNil(Snippet(command: "  \n").validationError)
        XCTAssertNil(Snippet(command: "claude").validationError)
        XCTAssertTrue(Snippet.defaults.contains { $0.command == "claude" })
        XCTAssertTrue(Snippet.defaults.allSatisfy { $0.validationError == nil })
    }

    func testSnippetCodable() throws {
        let snippets = Snippet.defaults
        let decoded = try JSONDecoder().decode([Snippet].self, from: JSONEncoder().encode(snippets))
        XCTAssertEqual(decoded, snippets)
        let minimal = try JSONDecoder().decode(Snippet.self, from: Data(#"{"command":"htop"}"#.utf8))
        XCTAssertEqual(minimal.command, "htop")
        XCTAssertTrue(minimal.sendReturn)
    }

    func testTerminalOutputDocumentCleaningAndANSIStripping() {
        let raw = "\u{1b}[32muser@host\u{1b}[0m:~$ ls -la   \r\ndrwxr-xr-x 2 root root\t  \r\n\u{1b}]0;title\u{07}error: connection refused\r\nwarning: deprecated: old api\r\n   \r\n\r\n"
        let doc = TerminalOutputDocument(rawText: raw, source: .tmux(sessionName: "dev"))
        XCTAssertEqual(doc.source, .tmux(sessionName: "dev"))
        XCTAssertEqual(doc.lines, [
            "user@host:~$ ls -la",
            "drwxr-xr-x 2 root root",
            "error: connection refused",
            "warning: deprecated: old api"
        ])
        XCTAssertEqual(doc.errorCount, 1)
        XCTAssertEqual(doc.warningCount, 1)
        XCTAssertEqual(doc.issueLineIndices, [2, 3])
    }

    func testTerminalOutputDocumentSearchAndExtraction() {
        let raw = "line 1: start\nLine 2: Error: failed to connect\nline 3: retry error: timeout\nline 4: done"
        let doc = TerminalOutputDocument(rawText: raw)
        let matches = doc.search("error")
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].lineIndex, 1)
        XCTAssertEqual(matches[0].lineNumber, 2)
        XCTAssertEqual(matches[1].lineIndex, 2)
        XCTAssertEqual(doc.text(fromLine: 2, toLine: 1), "Line 2: Error: failed to connect\nline 3: retry error: timeout")
        XCTAssertEqual(doc.tailText(lines: 2), "line 3: retry error: timeout\nline 4: done")
    }

    func testTmuxCapturePaneCommand() {
        let cmd = TmuxCommands().capturePane("my session", historyLines: 5000)
        XCTAssertTrue(cmd.contains("capture-pane -p -J -t '=my session' -S -5000"))
    }
}
