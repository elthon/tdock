import Foundation
import XCTest
@testable import TDockCore

final class TmuxCommandsTests: XCTestCase {
    func testShellQuote() {
        XCTAssertEqual(ShellQuote.quote("a b"), "'a b'")
        XCTAssertEqual(ShellQuote.quote("it's"), "'it'\\''s'")
        XCTAssertTrue(ShellQuote.script("command -v tmux").hasPrefix("sh -c '"))
    }

    func testNameValidation() {
        XCTAssertNoThrow(try TmuxCommands.validate("work"))
        XCTAssertNoThrow(try TmuxCommands.validate("开发 环境"))
        for bad in ["", "  ", "a:b", "a.b", "-x", "tab\there", String(repeating: "x", count: 65)] {
            XCTAssertThrowsError(try TmuxCommands.validate(bad), bad.debugDescription)
        }
    }

    func testParseSessions() {
        let output = "main:1700000000:1:3\nscratch pad:1700000100:0:1\ngarbage line\nbad:1:2\n"
        let sessions = TmuxCommands.parseSessions(output)
        XCTAssertEqual(sessions.map(\.name), ["main", "scratch pad"])
        XCTAssertTrue(sessions[0].isInUse)
        XCTAssertFalse(sessions[1].isInUse)
        XCTAssertEqual(sessions[0].windows, 3)
        XCTAssertEqual(sessions[1].createdAt, Date(timeIntervalSince1970: 1_700_000_100))
    }

    func testNoServerDetection() {
        XCTAssertTrue(TmuxCommands.isNoServerError("no server running on /tmp/tmux-1000/default\n"))
        XCTAssertTrue(TmuxCommands.isNoServerError("error connecting to /tmp/tmux-1000/default (No such file or directory)"))
        XCTAssertFalse(TmuxCommands.isNoServerError("permission denied"))
    }

    func testCommandsQuoteNames() throws {
        let cmd = try TmuxCommands().rename("old name", to: "new'name")
        XCTAssertTrue(cmd.contains("rename-session"))
        XCTAssertFalse(TmuxCommands.attachOrCreate("x").isEmpty)
    }
}
