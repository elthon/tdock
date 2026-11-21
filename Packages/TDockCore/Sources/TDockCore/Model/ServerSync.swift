import Foundation

/// 经 iCloud 同步的文档：服务器配置（不含任何密码/私钥）+ 删除记录（墓碑）。
public struct SyncDocument: Codable, Equatable, Sendable {
    public var servers: [ServerProfile]
    /// 服务器 ID → 删除时间。
    public var tombstones: [UUID: Date]

    public init(servers: [ServerProfile] = [], tombstones: [UUID: Date] = [:]) {
        self.servers = servers
        self.tombstones = tombstones
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SyncDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(SyncDocument.self, from: data)
    }
}

public enum ServerSync {
    /// 墓碑保留时长：超过后清理，避免无限增长。
    public static let tombstoneLifetime: TimeInterval = 90 * 24 * 3600

    /// 合并两份文档：同一服务器取 updatedAt 较新者；删除时间不早于修改时间则视为已删除。
    /// 结果保持 local 的顺序，remote 独有的条目按 remote 顺序追加。
    public static func merge(local: SyncDocument, remote: SyncDocument, now: Date = Date()) -> SyncDocument {
        var tombstones = local.tombstones
        for (id, date) in remote.tombstones {
            tombstones[id] = max(tombstones[id] ?? .distantPast, date)
        }

        var winners: [UUID: ServerProfile] = [:]
        for profile in local.servers + remote.servers {
            if let existing = winners[profile.id], existing.updatedAt >= profile.updatedAt { continue }
            winners[profile.id] = profile
        }

        var order: [UUID] = []
        var seen = Set<UUID>()
        for profile in local.servers + remote.servers where seen.insert(profile.id).inserted {
            order.append(profile.id)
        }

        let servers = order.compactMap { id -> ServerProfile? in
            guard let profile = winners[id] else { return nil }
            if let deleted = tombstones[id], deleted >= profile.updatedAt { return nil }
            return profile
        }
        // 已被更新的修改“复活”的服务器，其旧墓碑不再需要。
        for profile in servers { tombstones[profile.id] = nil }
        tombstones = tombstones.filter { now.timeIntervalSince($0.value) < tombstoneLifetime }
        return SyncDocument(servers: servers, tombstones: tombstones)
    }
}
