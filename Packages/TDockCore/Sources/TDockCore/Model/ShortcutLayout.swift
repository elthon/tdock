/// 键盘上方快捷栏的按键目录与布局（可自定义、可持久化）。
public enum ShortcutKey: String, Codable, CaseIterable, Identifiable, Sendable {
    // 修饰键（单次锁定，作用于下一次按键）
    case ctrl, alt
    // 常用
    case esc, tab, shiftTab, enter, backspace
    // 方向与导航（方向键按终端光标模式发送，由 UI 层交给 SwiftTerm 处理）
    case up, down, left, right, home, end, pageUp, pageDown
    // 组合键
    case ctrlC, ctrlD, ctrlZ, ctrlL, ctrlR, ctrlA, ctrlE, ctrlK, ctrlU, ctrlW, ctrlB
    // 符号
    case pipe, tilde, slash, backslash, dash, underscore, backtick, colon, semicolon, quote, doubleQuote
    // 功能键
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    public var id: String { rawValue }

    public enum Kind: Equatable, Sendable {
        case modifier
        case cursor
        case bytes([UInt8])
    }

    public var kind: Kind {
        switch self {
        case .ctrl, .alt: return .modifier
        case .up, .down, .left, .right, .home, .end: return .cursor
        default: return .bytes(bytes)
        }
    }

    /// 发送的字节（修饰键与光标键为空，由 UI 层处理）。
    public var bytes: [UInt8] {
        switch self {
        case .ctrl, .alt, .up, .down, .left, .right, .home, .end: return []
        case .esc: return [0x1B]
        case .tab: return [0x09]
        case .shiftTab: return [0x1B, 0x5B, 0x5A] // CSI Z
        case .enter: return [0x0D]
        case .backspace: return [0x7F]
        case .pageUp: return Array("\u{1b}[5~".utf8)
        case .pageDown: return Array("\u{1b}[6~".utf8)
        case .ctrlC: return Self.control("c")
        case .ctrlD: return Self.control("d")
        case .ctrlZ: return Self.control("z")
        case .ctrlL: return Self.control("l")
        case .ctrlR: return Self.control("r")
        case .ctrlA: return Self.control("a")
        case .ctrlE: return Self.control("e")
        case .ctrlK: return Self.control("k")
        case .ctrlU: return Self.control("u")
        case .ctrlW: return Self.control("w")
        case .ctrlB: return Self.control("b")
        case .pipe: return Array("|".utf8)
        case .tilde: return Array("~".utf8)
        case .slash: return Array("/".utf8)
        case .backslash: return Array("\\".utf8)
        case .dash: return Array("-".utf8)
        case .underscore: return Array("_".utf8)
        case .backtick: return Array("`".utf8)
        case .colon: return Array(":".utf8)
        case .semicolon: return Array(";".utf8)
        case .quote: return Array("'".utf8)
        case .doubleQuote: return Array("\"".utf8)
        case .f1: return Array("\u{1b}OP".utf8)
        case .f2: return Array("\u{1b}OQ".utf8)
        case .f3: return Array("\u{1b}OR".utf8)
        case .f4: return Array("\u{1b}OS".utf8)
        case .f5: return Array("\u{1b}[15~".utf8)
        case .f6: return Array("\u{1b}[17~".utf8)
        case .f7: return Array("\u{1b}[18~".utf8)
        case .f8: return Array("\u{1b}[19~".utf8)
        case .f9: return Array("\u{1b}[20~".utf8)
        case .f10: return Array("\u{1b}[21~".utf8)
        case .f11: return Array("\u{1b}[23~".utf8)
        case .f12: return Array("\u{1b}[24~".utf8)
        }
    }

    /// 按钮上显示的文字。
    public var label: String {
        switch self {
        case .ctrl: return "Ctrl"
        case .alt: return "Alt"
        case .esc: return "Esc"
        case .tab: return "Tab"
        case .shiftTab: return "⇧Tab"
        case .enter: return "⏎"
        case .backspace: return "⌫"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "PgUp"
        case .pageDown: return "PgDn"
        case .ctrlC: return "^C"
        case .ctrlD: return "^D"
        case .ctrlZ: return "^Z"
        case .ctrlL: return "^L"
        case .ctrlR: return "^R"
        case .ctrlA: return "^A"
        case .ctrlE: return "^E"
        case .ctrlK: return "^K"
        case .ctrlU: return "^U"
        case .ctrlW: return "^W"
        case .ctrlB: return "^B"
        case .pipe: return "|"
        case .tilde: return "~"
        case .slash: return "/"
        case .backslash: return "\\"
        case .dash: return "-"
        case .underscore: return "_"
        case .backtick: return "`"
        case .colon: return ":"
        case .semicolon: return ";"
        case .quote: return "'"
        case .doubleQuote: return "\""
        default: return rawValue.uppercased() // F1…F12
        }
    }

    /// 辅助功能 / 设置列表中的说明。
    public var title: String {
        switch self {
        case .ctrl: return "Ctrl（锁定，作用于下一键）"
        case .alt: return "Alt / Meta（锁定，作用于下一键）"
        case .ctrlC: return "Ctrl+C 中断"
        case .ctrlD: return "Ctrl+D 结束输入"
        case .ctrlZ: return "Ctrl+Z 挂起"
        case .ctrlL: return "Ctrl+L 清屏"
        case .ctrlR: return "Ctrl+R 搜索历史"
        case .ctrlA: return "Ctrl+A 行首"
        case .ctrlE: return "Ctrl+E 行尾"
        case .ctrlK: return "Ctrl+K 删除到行尾"
        case .ctrlU: return "Ctrl+U 删除到行首"
        case .ctrlW: return "Ctrl+W 删除前一个词"
        case .ctrlB: return "Ctrl+B（tmux 前缀）"
        case .shiftTab: return "Shift+Tab"
        case .up: return "上（历史）"
        case .down: return "下（历史）"
        case .left: return "左"
        case .right: return "右"
        default: return label
        }
    }

    /// 长按 Ctrl 弹出的常用组合键。
    public static let controlCombos: [ShortcutKey] = [.ctrlC, .ctrlD, .ctrlZ, .ctrlL, .ctrlR, .ctrlA, .ctrlE, .ctrlK, .ctrlU]

    /// Agent 抽屉（面向 agent CLI）：Esc、Tab 补全、Ctrl+C 中断、上下翻历史。
    public static let agentDrawer: [ShortcutKey] = [.esc, .tab, .ctrlC, .up, .down]

    /// Ctrl+字母 → 控制字符（字母 & 0x1F）。
    static func control(_ letter: Character) -> [UInt8] {
        [letter.asciiValue! & 0x1F]
    }
}

/// 快捷栏布局：多页，每页若干按键，可左右滑动切换。
public struct ShortcutLayout: Codable, Equatable, Sendable {
    public static let maxPages = 6
    public static let maxKeysPerPage = 12

    public var pages: [[ShortcutKey]]

    public init(pages: [[ShortcutKey]]) {
        self.pages = pages
    }

    /// 默认：第一页 Esc、Tab、Ctrl、Alt、←↑↓→（拇指可及）；后续为符号、导航、功能键。
    public static let `default` = ShortcutLayout(pages: [
        [.esc, .tab, .ctrl, .alt, .left, .up, .down, .right],
        [.pipe, .tilde, .slash, .dash, .underscore, .backtick, .shiftTab, .ctrlB],
        [.home, .end, .pageUp, .pageDown, .backslash, .colon, .quote, .doubleQuote],
        [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12],
    ])

    /// 去掉空页、截断超限内容；全部为空时回到默认布局。
    public func normalized() -> ShortcutLayout {
        let cleaned = pages
            .map { Array($0.prefix(Self.maxKeysPerPage)) }
            .filter { !$0.isEmpty }
            .prefix(Self.maxPages)
        return cleaned.isEmpty ? .default : ShortcutLayout(pages: Array(cleaned))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 未来版本删除某个按键时，旧数据中的未知按键被忽略而不是整体解码失败。
        let raw = try container.decode([[String]].self, forKey: .pages)
        pages = raw.map { $0.compactMap(ShortcutKey.init(rawValue:)) }
    }

    private enum CodingKeys: String, CodingKey { case pages }
}
