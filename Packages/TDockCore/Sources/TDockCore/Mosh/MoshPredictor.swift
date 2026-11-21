/// Mosh 本地回显预测（简化版）。
///
/// 规则：
/// - 只预测可打印字符；退格撤销最近一个未确认的预测；其它控制键/方向键清空预测并重置“回显已确认”。
/// - **只有在当前行已观察到服务器真实回显之后才显示预测**：回车后（例如进入密码提示）不会显示任何
///   未经服务器回显确认的输入，避免把密码画到屏幕上。
/// - 只在 RTT 较高（默认 > 30 ms）时显示，低延迟网络下没有必要。
/// - 服务器的 echo_ack 覆盖某个按键的状态号后，该预测被移除（真实回显已经在屏幕上）。
public struct MoshPredictor: Sendable {
    public static let rttThreshold: Double = 30
    /// 预测在这么久仍未被确认时清空（毫秒）。
    public static let staleAfter: UInt64 = 2000

    private struct Entry: Sendable {
        var text: String
        var stateNum: UInt64?
        var createdAt: UInt64
    }

    private var entries: [Entry] = []
    private var echoConfirmed = false
    private var recentOutput: [UInt8] = []

    public init() {}

    /// 当前应显示在光标处的预测文本（未满足显示条件时为空）。
    public func displayText(rtt: Double) -> String {
        guard echoConfirmed, rtt > Self.rttThreshold else { return "" }
        return entries.map(\.text).joined()
    }

    /// 用户输入（发送给服务器之前调用）。
    public mutating func userInput(_ bytes: [UInt8], now: UInt64) {
        var printable: [UInt8] = []
        func flushPrintable() {
            guard !printable.isEmpty else { return }
            for scalar in String(decoding: printable, as: UTF8.self).unicodeScalars {
                entries.append(Entry(text: String(scalar), stateNum: nil, createdAt: now))
            }
            printable = []
        }
        for byte in bytes {
            switch byte {
            case 0x20..<0x7F, 0x80...:
                printable.append(byte)
            case 0x7F, 0x08:
                flushPrintable()
                if entries.isEmpty {
                    echoConfirmed = false // 删除的是服务器上的字符，屏幕变化无法预测
                } else {
                    entries.removeLast()
                }
            default:
                // 回车、Esc、方向键、Ctrl 组合等：光标去向未知。
                flushPrintable()
                reset()
                return
            }
        }
        flushPrintable()
    }

    /// 按键发出后得到其所属的客户端状态号。
    public mutating func assign(stateNum: UInt64) {
        for index in entries.indices where entries[index].stateNum == nil {
            entries[index].stateNum = stateNum
        }
    }

    /// 服务器输出（用于判断是否真的回显了用户输入）。
    public mutating func hostOutput(_ bytes: [UInt8]) {
        recentOutput += bytes
        if recentOutput.count > 4096 { recentOutput.removeFirst(recentOutput.count - 4096) }
    }

    /// 服务器确认已处理并回显到状态号 num 为止的输入。
    public mutating func echoAcked(_ num: UInt64) {
        let confirmed = entries.filter { ($0.stateNum ?? .max) <= num }
        guard !confirmed.isEmpty else { return }
        let text = Array(confirmed.map(\.text).joined().utf8)
        echoConfirmed = Self.contains(recentOutput, text)
        recentOutput.removeAll()
        entries.removeAll { ($0.stateNum ?? .max) <= num }
        if !echoConfirmed { entries.removeAll() }
    }

    /// 定期调用：清理长时间未确认的预测。
    public mutating func expire(now: UInt64) {
        if let first = entries.first, now - first.createdAt > Self.staleAfter {
            reset()
        }
    }

    public mutating func reset() {
        entries.removeAll()
        echoConfirmed = false
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) { return true }
        }
        return false
    }
}
