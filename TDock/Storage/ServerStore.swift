import Foundation
import TDockCore

/// 服务器列表（非敏感字段）持久化到 Application Support/servers.json，删除记录（墓碑）在 tombstones.json。
final class ServerStore: ObservableObject {
    @Published private(set) var servers: [ServerProfile] = []
    private(set) var tombstones: [UUID: Date] = [:]

    /// 本地修改后回调（CloudSync 据此推送到 iCloud）。
    var onLocalChange: (() -> Void)?

    private let serversURL: URL
    private let tombstonesURL: URL

    init(
        serversURL: URL = AppFiles.url(for: "servers.json"),
        tombstonesURL: URL = AppFiles.url(for: "tombstones.json")
    ) {
        self.serversURL = serversURL
        self.tombstonesURL = tombstonesURL
        servers = AppFiles.load([ServerProfile].self, from: serversURL) ?? []
        tombstones = AppFiles.load([UUID: Date].self, from: tombstonesURL) ?? [:]
    }

    /// 新增或更新服务器。`secret` 为 nil 表示不修改已保存的凭据。
    func save(_ profile: ServerProfile, secret: String?) throws {
        var profile = profile
        profile.updatedAt = Date()
        if let secret {
            try KeychainStore.save(secret, for: profile.id, kind: .init(profile.authMethod))
        }
        // 切换认证方式/改用密钥库后，清除不再使用的旧凭据。
        if profile.authMethod == .password || profile.keyID != nil {
            KeychainStore.delete(for: profile.id, kind: .privateKey)
        }
        if profile.authMethod == .privateKey {
            KeychainStore.delete(for: profile.id, kind: .password)
        }

        if let index = servers.firstIndex(where: { $0.id == profile.id }) {
            servers[index] = profile
        } else {
            servers.append(profile)
        }
        tombstones[profile.id] = nil
        try persist()
        onLocalChange?()
    }

    func delete(_ profile: ServerProfile) {
        KeychainStore.deleteAll(for: profile.id)
        servers.removeAll { $0.id == profile.id }
        tombstones[profile.id] = Date()
        try? persist()
        onLocalChange?()
    }

    // MARK: - Sync

    @discardableResult
    func importBackup(_ backup: ServerBackup, policy: ServerBackup.ConflictPolicy) throws -> ServerBackup.ImportPlan {
        let plan = try backup.importPlan(current: servers, policy: policy)
        guard plan.changedCount > 0 else { return plan }
        // New imports must not pick up any stale credentials under the same UUID.
        for id in plan.credentialResetIDs.union(plan.addedIDs) {
            try KeychainStore.clearForImport(id)
        }
        var newTombstones = tombstones
        for id in plan.addedIDs.union(plan.updatedIDs) { newTombstones[id] = nil }
        try AppFiles.save(plan.servers, to: serversURL)
        do {
            try AppFiles.save(newTombstones, to: tombstonesURL)
        } catch {
            try? AppFiles.save(servers, to: serversURL)
            throw error
        }
        servers = plan.servers
        tombstones = newTombstones
        onLocalChange?()
        return plan
    }

    var document: SyncDocument {
        SyncDocument(servers: servers, tombstones: tombstones)
    }

    /// 应用合并后的文档（来自 iCloud）。被远端删除的服务器同时清除本机凭据。
    func apply(_ merged: SyncDocument) {
        guard merged != document else { return }
        let removed = Set(servers.map(\.id)).subtracting(merged.servers.map(\.id))
        removed.forEach(KeychainStore.deleteAll)
        servers = merged.servers
        tombstones = merged.tombstones
        try? persist()
    }

    private func persist() throws {
        try AppFiles.save(servers, to: serversURL)
        try AppFiles.save(tombstones, to: tombstonesURL)
    }
}

/// 应用私有 JSON 文件读写（仅用于非敏感数据）。
enum AppFiles {
    static func url(for name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
