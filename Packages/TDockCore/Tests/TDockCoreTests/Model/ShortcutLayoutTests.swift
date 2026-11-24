import Foundation
import XCTest
@testable import TDockCore

final class ShortcutLayoutTests: XCTestCase {
    func testControlEncoding() {
        XCTAssertEqual(ShortcutKey.ctrlC.bytes, [0x03])
        XCTAssertEqual(ShortcutKey.ctrlD.bytes, [0x04])
        XCTAssertEqual(ShortcutKey.ctrlZ.bytes, [0x1A])
        XCTAssertEqual(ShortcutKey.ctrlL.bytes, [0x0C])
        XCTAssertEqual(ShortcutKey.ctrlR.bytes, [0x12])
        XCTAssertEqual(ShortcutKey.ctrlA.bytes, [0x01])
        XCTAssertEqual(ShortcutKey.ctrlE.bytes, [0x05])
        XCTAssertEqual(ShortcutKey.ctrlK.bytes, [0x0B])
        XCTAssertEqual(ShortcutKey.ctrlU.bytes, [0x15])
        XCTAssertEqual(ShortcutKey.esc.bytes, [0x1B])
        XCTAssertEqual(ShortcutKey.tab.bytes, [0x09])
        XCTAssertEqual(ShortcutKey.f5.bytes, Array("\u{1b}[15~".utf8))
    }

    func testKinds() {
        XCTAssertEqual(ShortcutKey.ctrl.kind, .modifier)
        XCTAssertEqual(ShortcutKey.up.kind, .cursor)
        XCTAssertEqual(ShortcutKey.pageUp.kind, .cursor)
        XCTAssertEqual(ShortcutKey.pageDown.kind, .cursor)
        XCTAssertEqual(ShortcutKey.esc.kind, .bytes([0x1B]))
        XCTAssertEqual(ShortcutKey.paste.kind, .paste)
        XCTAssertTrue(ShortcutKey.paste.bytes.isEmpty)
        for key in ShortcutKey.allCases where key.kind != .modifier && key.kind != .cursor && key.kind != .paste {
            XCTAssertFalse(key.bytes.isEmpty, "\(key) 应发送字节")
            XCTAssertFalse(key.label.isEmpty)
        }
    }

    func testDefaultLayoutMatchesSpec() {
        XCTAssertEqual(ShortcutLayout.default.pages[0], [.esc, .tab, .ctrl, .alt, .left, .up, .down, .right])
        XCTAssertEqual(ShortcutKey.controlCombos, [.ctrlC, .ctrlD, .ctrlZ, .ctrlL, .ctrlR, .ctrlA, .ctrlE, .ctrlK, .ctrlU])
        XCTAssertEqual(ShortcutKey.agentDrawer, [.esc, .tab, .ctrlC, .up, .down, .paste])
        XCTAssertTrue(ShortcutLayout.default.pages.allSatisfy { $0.count <= ShortcutLayout.maxKeysPerPage })
    }

    func testNormalization() {
        XCTAssertEqual(ShortcutLayout(pages: [[], []]).normalized(), .default)
        let long = ShortcutLayout(pages: [Array(ShortcutKey.allCases), [.esc]]).normalized()
        XCTAssertEqual(long.pages[0].count, ShortcutLayout.maxKeysPerPage)
        XCTAssertEqual(long.pages[1], [.esc])
    }

    func testDecodingIgnoresUnknownKeys() throws {
        let json = #"{"pages":[["esc","teleport","tab"]]}"#
        let layout = try JSONDecoder().decode(ShortcutLayout.self, from: Data(json.utf8))
        XCTAssertEqual(layout.pages, [[.esc, .tab]])
        XCTAssertEqual(try JSONDecoder().decode(ShortcutLayout.self, from: JSONEncoder().encode(ShortcutLayout.default)), .default)
    }
}
