import Foundation

/// known_hosts 中的一条记录（tdock 自己的 JSON 格式：键 `[host]:port`，值 `keyType SHA256:…`）。
public struct KnownHostEntry: Equatable, Identifiable, Sendable {
    public var host: String
    public var port: Int
    public var keyType: String
    public var fingerprint: String

    public var id: String { Self.key(host: host, port: port) }

    public init(host: String, port: Int, keyType: String, fingerprint: String) {
        self.host = host
        self.port = port
        self.keyType = keyType
        self.fingerprint = fingerprint
    }

    /// 存储键。主机名不区分大小写。
    public static func key(host: String, port: Int) -> String {
        "[\(host.lowercased())]:\(port)"
    }

    /// 存储值。
    public static func value(keyType: String, fingerprint: String) -> String {
        "\(keyType) \(fingerprint)"
    }

    public var value: String { Self.value(keyType: keyType, fingerprint: fingerprint) }

    /// 从存储的键值对解析；格式不对时返回 nil。
    public init?(key: String, value: String) {
        guard key.hasPrefix("["), let close = key.lastIndex(of: "]") else { return nil }
        let host = String(key[key.index(after: key.startIndex)..<close])
        let rest = key[key.index(after: close)...]
        guard !host.isEmpty, rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        self.init(host: host, port: port, keyType: String(parts[0]), fingerprint: String(parts[1]))
    }

    /// 把存储字典转成按主机名、端口排序的列表（忽略无法解析的记录）。
    public static func list(_ entries: [String: String]) -> [KnownHostEntry] {
        entries.compactMap { KnownHostEntry(key: $0.key, value: $0.value) }
            .sorted { ($0.host, $0.port) < ($1.host, $1.port) }
    }
}

/// 断线自动重连的退避时间表：1 s、2 s、4 s，共 3 次。
public struct ReconnectPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var baseDelay: Double

    public init(maxAttempts: Int = 3, baseDelay: Double = 1) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
    }

    public static let `default` = ReconnectPolicy()

    /// 第 attempt 次（从 1 开始）尝试前的等待秒数；超出次数返回 nil。
    public func delay(beforeAttempt attempt: Int) -> Double? {
        guard attempt >= 1, attempt <= maxAttempts else { return nil }
        return baseDelay * Double(1 << (attempt - 1))
    }
}
