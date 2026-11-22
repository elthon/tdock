import Foundation

/// 常用命令片段：Agent 抽屉中一键发送（例如 `claude`、`git status`）。只保存在本机设置中，不含凭据。
public struct Snippet: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// 菜单中显示的名称；为空时显示命令本身。
    public var title: String
    public var command: String
    /// 发送后自动回车执行。
    public var sendReturn: Bool

    public init(id: UUID = UUID(), title: String = "", command: String, sendReturn: Bool = true) {
        self.id = id
        self.title = title
        self.command = command
        self.sendReturn = sendReturn
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? command : trimmed
    }

    /// 发送到终端的字节：换行统一为回车（与键盘 Enter 一致），按需追加回车。
    public var bytes: [UInt8] {
        var text = command.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if sendReturn && !text.hasSuffix("\r") { text += "\r" }
        return Array(text.utf8)
    }

    public var validationError: String? {
        command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "请填写命令" : nil
    }

    public static let maxCount = 30

    public static let defaults: [Snippet] = [
        Snippet(title: "Claude Code", command: "claude"),
        Snippet(command: "git status"),
        Snippet(command: "docker ps"),
        Snippet(title: "系统日志", command: "journalctl -f -n 100"),
        Snippet(title: "查看日志（输入文件名）", command: "tail -f ", sendReturn: false),
    ]

    private enum CodingKeys: String, CodingKey { case id, title, command, sendReturn }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        command = try c.decode(String.self, forKey: .command)
        sendReturn = try c.decodeIfPresent(Bool.self, forKey: .sendReturn) ?? true
    }
}
