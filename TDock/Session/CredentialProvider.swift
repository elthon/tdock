import Foundation
import TDockCore

/// 从 Keychain 读取服务器的登录凭据（只在内存中短暂存在，用完即弃）。
enum CredentialProvider {
    struct MissingCredential: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func credential(for profile: ServerProfile) throws -> SSHCredential {
        switch profile.authMethod {
        case .password:
            guard let password = try KeychainStore.load(for: profile.id, kind: .password) else {
                throw MissingCredential(reason: "本机未保存该服务器的密码（可能是从 iCloud 同步来的配置），请编辑服务器填写密码")
            }
            return .password(password)
        case .privateKey:
            let pem: String?
            if let keyID = profile.keyID {
                pem = try KeychainStore.load(for: keyID, kind: .libraryKey)
                if pem == nil {
                    throw MissingCredential(reason: "该服务器使用的密钥不在本机密钥库中，请编辑服务器重新选择密钥")
                }
            } else {
                pem = try KeychainStore.load(for: profile.id, kind: .privateKey)
            }
            guard let pem else {
                throw MissingCredential(reason: "本机未保存该服务器的私钥（可能是从 iCloud 同步来的配置），请编辑服务器粘贴私钥")
            }
            return .privateKey(try OpenSSHPrivateKey.parse(pem))
        }
    }
}
