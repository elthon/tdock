import Foundation

/// 服务器连接配置。只包含非敏感信息；密码/私钥按 `id` 存在 Keychain 中。
public struct ServerProfile: Codable, Identifiable, Hashable, Sendable {
    public enum AuthMethod: String, Codable, CaseIterable, Sendable {
        case password
        case privateKey
    }

    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: AuthMethod

    public init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: AuthMethod = .password
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
    }

    /// 列表中显示的名称：未命名时回退为 user@host。
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "\(username)@\(host)" : trimmed
    }

    /// 基本字段校验，返回错误描述；合法时返回 nil。
    public func validationError() -> String? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "请填写主机地址" }
        if username.trimmingCharacters(in: .whitespaces).isEmpty { return "请填写用户名" }
        if !(1...65535).contains(port) { return "端口必须在 1–65535 之间" }
        return nil
    }
}
