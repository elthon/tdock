import XCTest
@testable import TDockCore

final class TerminalThemeTests: XCTestCase {
    func testBuiltInThemesAreComplete() {
        XCTAssertFalse(TerminalTheme.builtIn.isEmpty)
        XCTAssertEqual(Set(TerminalTheme.builtIn.map(\.id)).count, TerminalTheme.builtIn.count, "ID 不可重复")
        for theme in TerminalTheme.builtIn {
            XCTAssertEqual(theme.ansi.count, 16, theme.id)
        }
        XCTAssertEqual(TerminalTheme.builtIn[0].id, TerminalTheme.defaultID)
    }

    func testHexParsing() {
        XCTAssertEqual(TerminalTheme.RGB(hex: "#0A0B0C"), .init(red: 10, green: 11, blue: 12))
        XCTAssertEqual(TerminalTheme.RGB(hex: "ffffff"), .init(red: 255, green: 255, blue: 255))
        XCTAssertNil(TerminalTheme.RGB(hex: "12345"))
        XCTAssertNil(TerminalTheme.RGB(hex: "GGGGGG"))
    }

    func testLookupFallsBackToDefault() {
        XCTAssertEqual(TerminalTheme.named("solarized-light").name, "Solarized Light")
        XCTAssertTrue(TerminalTheme.named("solarized-light").isLight)
        XCTAssertEqual(TerminalTheme.named("no-such-theme").id, TerminalTheme.defaultID)
    }
}
