import Foundation
import Security
import TDockCore

/// 密码与私钥的唯一存放位置。
///
/// - 使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`：仅设备解锁时可读，不随备份迁移到其他设备，不同步 iCloud。
/// - 以服务器 ID + 凭据类型作为 account。
enum KeychainStore {
    enum Kind: String {
        /// 某台服务器的密码（ID = 服务器 ID）
        case password
        /// 为某台服务器单独粘贴的私钥（ID = 服务器 ID）
        case privateKey
        /// 密钥库中的私钥（ID = 密钥 ID）
        case libraryKey
    }

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "Keychain 错误（\(status)）：\(message)"
        }
    }

    private static let service = "app.tdock.credentials"

    private static func account(_ serverID: UUID, _ kind: Kind) -> String {
        "\(serverID.uuidString).\(kind.rawValue)"
    }

    private static func baseQuery(_ serverID: UUID, _ kind: Kind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(serverID, kind),
        ]
    }

    static func save(_ secret: String, for serverID: UUID, kind: Kind) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(serverID, kind)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func load(for serverID: UUID, kind: Kind) throws -> String? {
        var query = baseQuery(serverID, kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure(status: status)
        }
    }

    static func delete(for serverID: UUID, kind: Kind) {
        SecItemDelete(baseQuery(serverID, kind) as CFDictionary)
    }

    static func deleteAll(for serverID: UUID) {
        delete(for: serverID, kind: .password)
        delete(for: serverID, kind: .privateKey)
    }
}

extension KeychainStore.Kind {
    init(_ method: ServerProfile.AuthMethod) {
        switch method {
        case .password: self = .password
        case .privateKey: self = .privateKey
        }
    }
}
