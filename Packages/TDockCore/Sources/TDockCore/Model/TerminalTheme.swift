import Foundation

/// 终端配色：前景、背景、光标与 16 色 ANSI 调色板（十六进制 RRGGBB）。
public struct TerminalTheme: Identifiable, Hashable, Sendable {
    public struct RGB: Hashable, Sendable {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// 解析 "RRGGBB" 或 "#RRGGBB"。
        public init?(hex: String) {
            let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
            red = UInt8(value >> 16 & 0xFF)
            green = UInt8(value >> 8 & 0xFF)
            blue = UInt8(value & 0xFF)
        }

        /// 相对亮度（0–1），用于判断浅色主题。
        public var luminance: Double {
            (0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)) / 255
        }
    }

    public let id: String
    public let name: String
    public let foreground: RGB
    public let background: RGB
    public let cursor: RGB
    /// 依次为 black, red, green, yellow, blue, magenta, cyan, white，及其 bright 版本。
    public let ansi: [RGB]

    public var isLight: Bool { background.luminance > 0.5 }

    init(id: String, name: String, fg: String, bg: String, cursor: String, ansi: [String]) {
        self.id = id
        self.name = name
        foreground = RGB(hex: fg)!
        background = RGB(hex: bg)!
        self.cursor = RGB(hex: cursor)!
        self.ansi = ansi.map { RGB(hex: $0)! }
    }

    public static let defaultID = "tdock-dark"

    public static func named(_ id: String) -> TerminalTheme {
        builtIn.first { $0.id == id } ?? builtIn[0]
    }

    public static let builtIn: [TerminalTheme] = [
        TerminalTheme(
            id: "tdock-dark", name: "默认深色", fg: "E5E5E5", bg: "000000", cursor: "E5E5E5",
            ansi: ["000000", "CD3131", "0DBC79", "E5E510", "2472C8", "BC3FBC", "11A8CD", "E5E5E5",
                   "666666", "F14C4C", "23D18B", "F5F543", "3B8EEA", "D670D6", "29B8DB", "FFFFFF"]
        ),
        TerminalTheme(
            id: "tdock-light", name: "默认浅色", fg: "1E1E1E", bg: "FFFFFF", cursor: "1E1E1E",
            ansi: ["000000", "CD3131", "00BC00", "949800", "0451A5", "BC05BC", "0598BC", "555555",
                   "666666", "CD3131", "14CE14", "B5BA00", "0451A5", "BC05BC", "0598BC", "A5A5A5"]
        ),
        TerminalTheme(
            id: "solarized-dark", name: "Solarized Dark", fg: "839496", bg: "002B36", cursor: "93A1A1",
            ansi: ["073642", "DC322F", "859900", "B58900", "268BD2", "D33682", "2AA198", "EEE8D5",
                   "002B36", "CB4B16", "586E75", "657B83", "839496", "6C71C4", "93A1A1", "FDF6E3"]
        ),
        TerminalTheme(
            id: "solarized-light", name: "Solarized Light", fg: "657B83", bg: "FDF6E3", cursor: "586E75",
            ansi: ["073642", "DC322F", "859900", "B58900", "268BD2", "D33682", "2AA198", "EEE8D5",
                   "002B36", "CB4B16", "586E75", "657B83", "839496", "6C71C4", "93A1A1", "FDF6E3"]
        ),
        TerminalTheme(
            id: "tomorrow-night", name: "Tomorrow Night", fg: "C5C8C6", bg: "1D1F21", cursor: "C5C8C6",
            ansi: ["1D1F21", "CC6666", "B5BD68", "F0C674", "81A2BE", "B294BB", "8ABEB7", "C5C8C6",
                   "969896", "CC6666", "B5BD68", "F0C674", "81A2BE", "B294BB", "8ABEB7", "FFFFFF"]
        ),
        TerminalTheme(
            id: "gruvbox-dark", name: "Gruvbox Dark", fg: "EBDBB2", bg: "282828", cursor: "EBDBB2",
            ansi: ["282828", "CC241D", "98971A", "D79921", "458588", "B16286", "689D6A", "A89984",
                   "928374", "FB4934", "B8BB26", "FABD2F", "83A598", "D3869B", "8EC07C", "EBDBB2"]
        ),
    ]

    /// 终端字号范围（pt）。
    public static let fontSizeRange: ClosedRange<Double> = 9...24
    public static let defaultFontSize: Double = 13
}
