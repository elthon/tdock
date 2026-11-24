import Foundation

/// 终端缓冲区全文查看、搜索、错误定位与范围摘录（纯逻辑，可单元测试）。
public struct TerminalOutputDocument: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// 来自本地 SwiftTerm 缓冲区
        case localBuffer
        /// 来自远端 tmux capture-pane 的历史缓冲区
        case tmux(sessionName: String)
    }

    public enum IssueKind: String, Equatable, Sendable {
        case error
        case warning
    }

    /// 某一行中的关键词匹配区间（UTF-16 偏移，方便与 NSAttributedString / UITextView 对齐，同时保留 Range<String.Index>）。
    public struct LineMatch: Equatable, Identifiable, Sendable {
        /// 0-based 行索引（对应 `lines[lineIndex]`）
        public let lineIndex: Int
        /// 1-based 显示行号
        public var lineNumber: Int { lineIndex + 1 }
        /// 在该行内的 UTF-16 范围
        public let utf16Range: NSRange

        public var id: String { "\(lineIndex):\(utf16Range.location):\(utf16Range.length)" }

        public init(lineIndex: Int, utf16Range: NSRange) {
            self.lineIndex = lineIndex
            self.utf16Range = utf16Range
        }
    }

    public let source: Source
    /// 清洗后的所有行（去掉末尾全部空白的冗余空行，保留行内缩进但去除行尾填充空格）。
    public let lines: [String]
    /// 每一行是否存在 error / warning 特征（与 `lines` 等长）。
    public let lineIssues: [IssueKind?]
    /// 含有 error 或 warning 的行索引列表（0-based）。
    public let issueLineIndices: [Int]

    /// 完整纯文本（`\n` 连接）。
    public var fullText: String {
        lines.joined(separator: "\n")
    }

    public var totalLines: Int { lines.count }
    public var errorCount: Int { lineIssues.lazy.compactMap { $0 == .error ? $0 : nil }.count }
    public var warningCount: Int { lineIssues.lazy.compactMap { $0 == .warning ? $0 : nil }.count }

    public init(rawText: String, source: Source = .localBuffer) {
        self.source = source
        let cleaned = Self.cleanLines(from: rawText)
        self.lines = cleaned
        let issues = cleaned.map(Self.detectIssue(in:))
        self.lineIssues = issues
        self.issueLineIndices = issues.enumerated().compactMap { $0.element != nil ? $0.offset : nil }
    }

    // MARK: - Text Normalization & ANSI Stripping

    /// 剥离 ANSI CSI / OSC 转义序列与回车符，并裁掉终端缓冲区尾部空白行和每行末尾的空格填充。
    public static func cleanLines(from raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        let stripped = stripANSI(raw).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var rawLines = stripped.components(separatedBy: "\n").map(trimTrailingSpaces)
        while let last = rawLines.last, last.isEmpty {
            rawLines.removeLast()
        }
        return rawLines
    }

    /// 高速状态机剥离 ANSI CSI (`ESC [ ...`)、OSC (`ESC ] ... BEL/ST`) 及双字符 ESC 序列，不依赖慢速正则。
    public static func stripANSI(_ text: String) -> String {
        guard text.utf8.contains(0x1B) || text.utf8.contains(0x00) else { return text }
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(text.unicodeScalars.count)
        var iterator = text.unicodeScalars.makeIterator()

        while let scalar = iterator.next() {
            if scalar.value == 0x00 { continue }
            guard scalar.value == 0x1B else {
                scalars.append(scalar)
                continue
            }
            guard let next = iterator.next() else { break }
            switch next.value {
            case 0x5B: // '[' CSI: 参数字节 0x30...0x3F，中间字节 0x20...0x2F，终止字节 0x40...0x7E
                while let c = iterator.next() {
                    if c.value >= 0x40 && c.value <= 0x7E { break }
                }
            case 0x5D: // ']' OSC: 直到 BEL (0x07) 或 ST (ESC \)
                var prevWasEsc = false
                while let c = iterator.next() {
                    if c.value == 0x07 { break }
                    if prevWasEsc && c.value == 0x5C { break }
                    prevWasEsc = (c.value == 0x1B)
                }
            default:
                // 单字符 ESC 序列（如 ESC M, ESC 7, ESC 8）
                break
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func trimTrailingSpaces(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex {
            let prev = line.index(before: end)
            let ch = line[prev]
            if ch == " " || ch == "\t" || ch == "\0" {
                end = prev
            } else {
                break
            }
        }
        return String(line[..<end])
    }

    // MARK: - Issue Detection (Error / Warning)

    private static let errorTokens: [String] = [
        "error:", "error[", "fatal:", "panic:", "exception:", "traceback (most recent call last)",
        "segmentation fault", "permission denied", "command not found", "connection refused",
        "failed:", "failure:", "err!", "[error]", "✗", "❌"
    ]

    private static let warningTokens: [String] = [
        "warning:", "warn:", "[warn]", "[warning]", "deprecated:"
    ]

    /// 判断单行是否包含常见错误或警告标志。
    public static func detectIssue(in line: String) -> IssueKind? {
        guard !line.isEmpty else { return nil }
        let lower = line.lowercased()
        for token in errorTokens where lower.contains(token) {
            return .error
        }
        for token in warningTokens where lower.contains(token) {
            return .warning
        }
        return nil
    }

    // MARK: - Search

    /// 在所有行中搜索关键词（不区分大小写），返回按行号与列位置排序的所有匹配项。
    public func search(_ query: String) -> [LineMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var matches: [LineMatch] = []
        for (index, line) in lines.enumerated() where !line.isEmpty {
            let nsLine = line as NSString
            var searchRange = NSRange(location: 0, length: nsLine.length)
            while searchRange.length > 0 {
                let found = nsLine.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                guard found.location != NSNotFound, found.length > 0 else { break }
                matches.append(LineMatch(lineIndex: index, utf16Range: found))
                let nextLocation = found.location + found.length
                guard nextLocation < nsLine.length else { break }
                searchRange = NSRange(location: nextLocation, length: nsLine.length - nextLocation)
            }
        }
        return matches
    }

    // MARK: - Range & Tail Extraction

    /// 提取两个行索引（0-based，包含两端，顺序不限）之间的文本。
    public func text(fromLine start: Int, toLine end: Int) -> String {
        guard !lines.isEmpty else { return "" }
        let low = max(0, min(start, end))
        let high = min(lines.count - 1, max(start, end))
        guard low <= high else { return "" }
        return lines[low...high].joined(separator: "\n")
    }

    /// 提取最后 N 行文本（常用于一键复制最后 50 行报错喂给 AI）。
    public func tailText(lines count: Int) -> String {
        guard count > 0, !lines.isEmpty else { return "" }
        return lines.suffix(count).joined(separator: "\n")
    }
}
