import Foundation

/// 服务器连接配置。只包含非敏感信息（可经 iCloud 同步）；密码/私钥只在本机 Keychain 中。
public struct ServerProfile: Codable, Identifiable, Hashable, Sendable {
    public enum AuthMethod: String, Codable, CaseIterable, Sendable {
        case password
        case privateKey
    }

    /// 终端会话的传输方式。
    public enum Transport: String, Codable, CaseIterable, Sendable {
        case ssh
        case mosh
    }

    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: AuthMethod
    /// 私钥认证时，引用密钥库中的密钥；nil 表示使用为该服务器单独粘贴的私钥。
    public var keyID: UUID?
    public var transport: Transport
    public var portForwards: [PortForwardRule]
    /// 分组名（空字符串表示未分组），用于服务器列表分区。
    public var group: String
    /// 置顶显示。
    public var pinned: Bool
    /// 最后修改时间，用于多设备同步合并（后写者胜）。
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: AuthMethod = .password,
        keyID: UUID? = nil,
        transport: Transport = .ssh,
        portForwards: [PortForwardRule] = [],
        group: String = "",
        pinned: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.keyID = keyID
        self.transport = transport
        self.portForwards = portForwards
        self.group = group
        self.pinned = pinned
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authMethod, keyID, transport, portForwards, group, pinned, updatedAt
    }

    /// 兼容早期版本保存的数据（缺少后来新增的字段）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decode(String.self, forKey: .username)
        authMethod = try c.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .password
        keyID = try c.decodeIfPresent(UUID.self, forKey: .keyID)
        transport = try c.decodeIfPresent(Transport.self, forKey: .transport) ?? .ssh
        portForwards = try c.decodeIfPresent([PortForwardRule].self, forKey: .portForwards) ?? []
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }

    /// 列表中显示的名称：未命名时回退为 user@host。
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "\(username)@\(host)" : trimmed
    }

    /// 去掉首尾空白后的分组名。
    public var groupName: String { group.trimmingCharacters(in: .whitespaces) }

    /// 基本字段校验，返回错误描述；合法时返回 nil。
    public func validationError() -> String? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "请填写主机地址" }
        if username.trimmingCharacters(in: .whitespaces).isEmpty { return "请填写用户名" }
        if !(1...65535).contains(port) { return "端口必须在 1–65535 之间" }
        for rule in portForwards {
            if let error = rule.validationError() { return error }
        }
        return nil
    }
}

/// 本地端口转发规则：手机上 127.0.0.1:localPort → （经 SSH）remoteHost:remotePort。
public struct PortForwardRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int
    /// 选填备注名，例如“远程面板”。
    public var name: String

    public init(id: UUID = UUID(), localPort: Int, remoteHost: String, remotePort: Int, name: String = "") {
        self.id = id
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case id, localPort, remoteHost, remotePort, name
    }

    /// 兼容没有备注字段的旧数据。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        localPort = try c.decode(Int.self, forKey: .localPort)
        remoteHost = try c.decode(String.self, forKey: .remoteHost)
        remotePort = try c.decode(Int.self, forKey: .remotePort)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }

    public var summary: String { "localhost:\(localPort) → \(remoteHost):\(remotePort)" }

    /// 列表标题：有备注时显示备注，否则显示转发摘要。
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? summary : trimmed
    }

    /// 本机访问地址（转发监听在 127.0.0.1）。
    public var localAddress: String { "127.0.0.1:\(localPort)" }

    /// 在浏览器中打开的地址。
    public var localURL: URL { URL(string: "http://127.0.0.1:\(localPort)")! }

    public func validationError() -> String? {
        if !(1024...65535).contains(localPort) { return "本地端口需在 1024–65535 之间" }
        if remoteHost.trimmingCharacters(in: .whitespaces).isEmpty { return "请填写目标地址" }
        if !(1...65535).contains(remotePort) { return "目标端口必须在 1–65535 之间" }
        return nil
    }
}
