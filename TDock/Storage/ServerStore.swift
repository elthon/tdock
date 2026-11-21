import Foundation
import TDockCore

/// 服务器列表（非敏感字段）持久化到 Application Support/servers.json。
final class ServerStore: ObservableObject {
    @Published private(set) var servers: [ServerProfile] = []

    private let fileURL: URL

    init(fileURL: URL = AppFiles.url(for: "servers.json")) {
        self.fileURL = fileURL
        servers = AppFiles.load([ServerProfile].self, from: fileURL) ?? []
    }

    /// 新增或更新服务器。`secret` 为 nil 表示不修改已保存的凭据。
    func save(_ profile: ServerProfile, secret: String?) throws {
        if let secret {
            try KeychainStore.save(secret, for: profile.id, kind: .init(profile.authMethod))
        }
        // 切换认证方式后，清除另一种方式的旧凭据。
        let unused: KeychainStore.Kind = profile.authMethod == .password ? .privateKey : .password
        KeychainStore.delete(for: profile.id, kind: unused)

        if let index = servers.firstIndex(where: { $0.id == profile.id }) {
            servers[index] = profile
        } else {
            servers.append(profile)
        }
        try persist()
    }

    func delete(_ profile: ServerProfile) {
        KeychainStore.deleteAll(for: profile.id)
        servers.removeAll { $0.id == profile.id }
        try? persist()
    }

    private func persist() throws {
        try AppFiles.save(servers, to: fileURL)
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
