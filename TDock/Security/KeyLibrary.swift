import Foundation
import TDockCore

/// 密钥库（生成或导入）。私钥只在 Keychain（kind = .libraryKey）；这里只保存公开的元数据（名称、公钥、指纹）。
@MainActor
final class KeyLibrary: ObservableObject {
    struct Key: Codable, Identifiable, Hashable {
        let id: UUID
        var name: String
        let publicKey: String
        let fingerprint: String
        let createdAt: Date

        /// 显示用的类型名（由公钥前缀推导）。
        var typeName: String {
            if publicKey.hasPrefix("ssh-ed25519") { return "Ed25519" }
            if publicKey.hasPrefix("ecdsa-sha2-nistp256") { return "ECDSA P-256" }
            if publicKey.hasPrefix("ecdsa-sha2-nistp384") { return "ECDSA P-384" }
            if publicKey.hasPrefix("ecdsa-sha2-nistp521") { return "ECDSA P-521" }
            return String(publicKey.prefix { $0 != " " })
        }
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

    /// 导入已有私钥（未加密 OpenSSH 格式的 Ed25519 / ECDSA）：校验后写入 Keychain，公开信息由私钥推导。
    @discardableResult
    func importKey(name: String, privateKeyPEM: String) throws -> Key {
        let pem = privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? "导入-\(Self.dateStamp())" : trimmed
        let info = try OpenSSHKeyGenerator.importedKeyInfo(privateKeyPEM: pem, comment: label)
        if let existing = keys.first(where: { $0.fingerprint == info.fingerprint }) {
            throw ImportError.duplicate(existing.name)
        }
        let key = Key(id: UUID(), name: label, publicKey: info.publicKey, fingerprint: info.fingerprint, createdAt: Date())
        try KeychainStore.save(pem, for: key.id, kind: .libraryKey)
        keys.append(key)
        try persist()
        return key
    }

    enum ImportError: LocalizedError {
        case duplicate(String)
        var errorDescription: String? {
            switch self {
            case .duplicate(let name): return "密钥库中已有这把密钥（\(name)）"
            }
        }
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
