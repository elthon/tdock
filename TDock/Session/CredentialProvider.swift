import Foundation
import TDockCore

/// 从 Keychain 读取服务器的登录凭据（只在内存中短暂存在，用完即弃）。
enum CredentialProvider {
    struct MissingCredential: LocalizedError, Equatable {
        enum Kind: Equatable {
            /// 本机没有该服务器的密码
            case password
            /// 本机没有为该服务器单独粘贴的私钥
            case privateKey
            /// 服务器引用的密钥库密钥不在本机
            case libraryKey
        }

        let kind: Kind
        let hostID: UUID

        var errorDescription: String? {
            switch kind {
            case .password: return "本机未保存该服务器的密码（配置可能来自同步或文件导入）"
            case .privateKey: return "本机未保存该服务器的私钥（配置可能来自同步或文件导入）"
            case .libraryKey: return "该服务器使用的密钥不在本机密钥库中"
            }
        }
    }

    static func credential(for profile: ServerProfile) throws -> SSHCredential {
        switch profile.authMethod {
        case .password:
            guard let password = try KeychainStore.load(for: profile.id, kind: .password) else {
                throw MissingCredential(kind: .password, hostID: profile.id)
            }
            return .password(password)
        case .privateKey:
            if let keyID = profile.keyID {
                guard let pem = try KeychainStore.load(for: keyID, kind: .libraryKey) else {
                    throw MissingCredential(kind: .libraryKey, hostID: profile.id)
                }
                return .privateKey(try OpenSSHPrivateKey.parse(pem))
            }
            guard let pem = try KeychainStore.load(for: profile.id, kind: .privateKey) else {
                throw MissingCredential(kind: .privateKey, hostID: profile.id)
            }
            return .privateKey(try OpenSSHPrivateKey.parse(pem))
        }
    }
}
