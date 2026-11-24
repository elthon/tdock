import Foundation

/// A manually transported snapshot. No tombstones, credentials, or host trust records.
public struct ServerBackup: Codable, Sendable {
    public static let formatIdentifier = "tdock.server-backup"
    public static let maximumFileSize = 10 * 1024 * 1024
    public let format: String
    public let version: Int
    public let exportedAt: Date
    public let servers: [ServerProfile]

    public enum Failure: LocalizedError {
        case invalidFormat, unsupportedVersion, tooLarge, duplicateIdentifier, invalidServer(String)

        public var errorDescription: String? {
            switch self {
            case .invalidFormat: return "这不是有效的 TDock 服务器备份文件。"
            case .unsupportedVersion: return "备份版本暂不支持，请更新 TDock 后再导入。"
            case .tooLarge: return "备份过大：最多支持 10 MB、5,000 条服务器配置。"
            case .duplicateIdentifier: return "文件包含重复的服务器标识，请检查备份文件。"
            case .invalidServer(let message): return "备份配置无效：\(message)"
            }
        }
    }

    public init(servers: [ServerProfile], exportedAt: Date = Date()) {
        format = Self.formatIdentifier
        version = 1
        self.exportedAt = exportedAt
        // A source device's key-library identifiers are not portable credentials.
        self.servers = servers.map { profile in
            var copy = profile
            copy.keyID = nil
            return copy
        }
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumFileSize else { throw Failure.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> ServerBackup {
        guard data.count <= maximumFileSize else { throw Failure.tooLarge }
        let backup: ServerBackup
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            backup = try decoder.decode(Self.self, from: data)
        } catch { throw Failure.invalidFormat }
        try backup.validate()
        return Self(servers: backup.servers, exportedAt: backup.exportedAt)
    }

    private func validate() throws {
        guard format == Self.formatIdentifier else { throw Failure.invalidFormat }
        guard version == 1 else { throw Failure.unsupportedVersion }
        guard servers.count <= 5_000 else { throw Failure.tooLarge }
        var identifiers = Set<UUID>()
        for server in servers {
            guard identifiers.insert(server.id).inserted else { throw Failure.duplicateIdentifier }
            if let error = server.validationError() { throw Failure.invalidServer(error) }
        }
    }

    public enum ConflictPolicy: String, CaseIterable, Identifiable, Sendable {
        case keepLocal, useFile
        public var id: Self { self }
    }

    public struct ImportPlan: Sendable {
        public let servers: [ServerProfile]
        public let addedIDs: Set<UUID>
        public let updatedIDs: Set<UUID>
        public let credentialResetIDs: Set<UUID>
        public let skipped: Int
        public var changedCount: Int { addedIDs.count + updatedIDs.count }
    }

    /// Match by stable configuration ID. Never remove unrelated local servers.
    public func importPlan(current: [ServerProfile], policy: ConflictPolicy, now: Date = Date()) throws -> ImportPlan {
        try validate()
        var result = current
        var indexes: [UUID: Int] = [:]
        for (index, profile) in current.enumerated() { indexes[profile.id] = index }
        var added = Set<UUID>(), updated = Set<UUID>(), resets = Set<UUID>()
        var skipped = 0
        for original in servers {
            var incoming = original
            incoming.keyID = nil
            if let index = indexes[incoming.id] {
                let local = result[index]
                guard policy == .useFile else { skipped += 1; continue }
                let sameCredential = local.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    == incoming.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    && local.port == incoming.port && local.username == incoming.username
                    && local.authMethod == incoming.authMethod
                if sameCredential { incoming.keyID = local.keyID }
                var comparison = incoming
                comparison.updatedAt = local.updatedAt
                guard comparison != local else { skipped += 1; continue }
                if !sameCredential { resets.insert(local.id) }
                incoming.updatedAt = now
                result[index] = incoming
                updated.insert(local.id)
            } else {
                incoming.updatedAt = now
                indexes[incoming.id] = result.count
                result.append(incoming)
                added.insert(incoming.id)
            }
        }
        return ImportPlan(servers: result, addedIDs: added, updatedIDs: updated,
                          credentialResetIDs: resets, skipped: skipped)
    }
}
