import Foundation
import TDockCore

/// 已信任的主机公钥指纹（TOFU）。指纹是公开信息，存于 Application Support/known_hosts.json。
final class KnownHostsStore {
    enum Verdict: Equatable {
        case trusted
        case unknown
        case mismatch(expected: String)
    }

    static let shared = KnownHostsStore()

    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [String: String]

    init(fileURL: URL = AppFiles.url(for: "known_hosts.json")) {
        self.fileURL = fileURL
        entries = AppFiles.load([String: String].self, from: fileURL) ?? [:]
    }

    func verdict(host: String, port: Int, key: HostKeyInfo) -> Verdict {
        lock.lock(); defer { lock.unlock() }
        guard let stored = entries[Self.entryKey(host, port)] else { return .unknown }
        return stored == Self.entryValue(key) ? .trusted : .mismatch(expected: stored)
    }

    func trust(host: String, port: Int, key: HostKeyInfo) {
        lock.lock(); defer { lock.unlock() }
        entries[Self.entryKey(host, port)] = Self.entryValue(key)
        try? AppFiles.save(entries, to: fileURL)
    }

    /// 用新的记录值（`keyType SHA256:…`，来自指纹不匹配错误中的“当前”值）替换。
    func replace(host: String, port: Int, value: String) {
        lock.lock(); defer { lock.unlock() }
        entries[Self.entryKey(host, port)] = value
        try? AppFiles.save(entries, to: fileURL)
    }

    /// 全部记录（设置 → 已信任主机）。
    var allEntries: [KnownHostEntry] {
        lock.lock(); defer { lock.unlock() }
        return KnownHostEntry.list(entries)
    }

    /// 删除记录：下次连接时重新走首次信任确认。
    func remove(_ entry: KnownHostEntry) {
        lock.lock(); defer { lock.unlock() }
        entries[entry.id] = nil
        try? AppFiles.save(entries, to: fileURL)
    }

    /// 每个 主机+端口 只记录一把密钥；密钥类型变化同样视为不匹配。
    private static func entryKey(_ host: String, _ port: Int) -> String {
        KnownHostEntry.key(host: host, port: port)
    }

    private static func entryValue(_ key: HostKeyInfo) -> String {
        KnownHostEntry.value(keyType: key.keyType, fingerprint: key.fingerprint)
    }
}
