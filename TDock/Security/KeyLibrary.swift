import Foundation
import TDockCore

/// 密钥库。私钥只在 Keychain（kind = .libraryKey）；这里只保存公开的元数据（名称、公钥、指纹）。
@MainActor
final class KeyLibrary: ObservableObject {
    struct Key: Codable, Identifiable, Hashable {
        let id: UUID
        var name: String
        let publicKey: String
        let fingerprint: String
        let createdAt: Date
    }

    @Published private(set) var keys: [Key] = []
    private let fileURL: URL

    init(fileURL: URL = AppFiles.url(for: "keys.json")) {
        self.fileURL = fileURL
        keys = AppFiles.load([Key].self, from: fileURL) ?? []
    }

    /// 生成 Ed25519 密钥对：私钥写入 Keychain，返回公开信息。
    @discardableResult
    func generate(name: String) throws -> Key {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? "tdock-\(Self.dateStamp())" : trimmed
        let pair = OpenSSHKeyGenerator.ed25519(comment: label.replacingOccurrences(of: " ", with: "-"))
        let key = Key(id: UUID(), name: label, publicKey: pair.publicKey, fingerprint: pair.fingerprint, createdAt: Date())
        try KeychainStore.save(pair.privateKeyPEM, for: key.id, kind: .libraryKey)
        keys.append(key)
        try persist()
        return key
    }

    func delete(_ key: Key) {
        KeychainStore.delete(for: key.id, kind: .libraryKey)
        keys.removeAll { $0.id == key.id }
        try? persist()
    }

    func key(_ id: UUID?) -> Key? {
        id.flatMap { id in keys.first { $0.id == id } }
    }

    private func persist() throws {
        try AppFiles.save(keys, to: fileURL)
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }
}
