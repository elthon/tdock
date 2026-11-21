import XCTest
@testable import TDockCore

final class MoshPredictorTests: XCTestCase {
    private let slow: Double = 120

    /// 服务器回显了 "l" 之后，后续输入以预测方式立即显示。
    func testPredictsAfterConfirmedEcho() {
        var p = MoshPredictor()
        p.userInput(Array("l".utf8), now: 0)
        p.assign(stateNum: 5)
        XCTAssertEqual(p.displayText(rtt: slow), "", "未确认回显前不显示")
        p.hostOutput(Array("l".utf8))
        p.echoAcked(5)

        p.userInput(Array("s -".utf8), now: 10)
        p.assign(stateNum: 6)
        XCTAssertEqual(p.displayText(rtt: slow), "s -")
        XCTAssertEqual(p.displayText(rtt: 10), "", "低延迟时不显示")

        p.hostOutput(Array("s -".utf8))
        p.echoAcked(6)
        XCTAssertEqual(p.displayText(rtt: slow), "")
    }

    /// 回车后进入密码提示：服务器不回显，输入绝不显示。
    func testNeverShowsUnechoedInputAfterEnter() {
        var p = MoshPredictor()
        p.userInput(Array("sudo ls".utf8), now: 0)
        p.assign(stateNum: 1)
        p.hostOutput(Array("sudo ls".utf8))
        p.echoAcked(1)
        p.userInput([0x0D], now: 1)
        p.hostOutput(Array("\r\n[sudo] password: ".utf8))

        p.userInput(Array("secret".utf8), now: 2)
        p.assign(stateNum: 2)
        XCTAssertEqual(p.displayText(rtt: slow), "")
        p.echoAcked(2) // 服务器处理了但没有回显
        p.userInput(Array("more".utf8), now: 3)
        p.assign(stateNum: 3)
        XCTAssertEqual(p.displayText(rtt: slow), "", "回显未被确认时保持不显示")
    }

    func testBackspaceAndControlKeys() {
        var p = MoshPredictor()
        p.userInput(Array("a".utf8), now: 0)
        p.assign(stateNum: 1)
        p.hostOutput(Array("a".utf8))
        p.echoAcked(1)

        p.userInput(Array("bc".utf8) + [0x7F], now: 1)
        XCTAssertEqual(p.displayText(rtt: slow), "b")
        p.userInput([0x1B, 0x5B, 0x44], now: 2) // ←
        XCTAssertEqual(p.displayText(rtt: slow), "")
    }

    func testStalePredictionsExpire() {
        var p = MoshPredictor()
        p.userInput(Array("x".utf8), now: 0)
        p.assign(stateNum: 1)
        p.hostOutput(Array("x".utf8))
        p.echoAcked(1)
        p.userInput(Array("y".utf8), now: 100)
        XCTAssertEqual(p.displayText(rtt: slow), "y")
        p.expire(now: 100 + MoshPredictor.staleAfter + 1)
        XCTAssertEqual(p.displayText(rtt: slow), "")
    }

    func testUnicodeInput() {
        var p = MoshPredictor()
        p.userInput(Array("中".utf8), now: 0)
        p.assign(stateNum: 1)
        p.hostOutput(Array("中".utf8))
        p.echoAcked(1)
        p.userInput(Array("文".utf8), now: 1)
        XCTAssertEqual(p.displayText(rtt: slow), "文")
    }

    func testConnectLineParsingAndKey() {
        let info = MoshSession.parseConnectLine("\r\nMOSH CONNECT 60001 4NeCCgvZFe2RnPgrcU1PQw\r\n\nmosh-server (mosh 1.4.0)\n")
        XCTAssertEqual(info, .init(port: 60001, key: "4NeCCgvZFe2RnPgrcU1PQw"))
        XCTAssertNil(MoshSession.parseConnectLine("MOSH CONNECT 0 4NeCCgvZFe2RnPgrcU1PQw"))
        XCTAssertNil(MoshSession.parseConnectLine("nothing here"))
        XCTAssertEqual(MoshSession.decodeKey("4NeCCgvZFe2RnPgrcU1PQw")?.count, 16)
        XCTAssertNil(MoshSession.decodeKey("short"))
    }
}
