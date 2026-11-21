import Crypto
import Foundation
import NIOSSH

public enum SSHSessionError: Error, LocalizedError, Equatable {
    case connectFailed(host: String, port: Int, reason: String)
    case authenticationFailed
    case noSupportedAuthMethod
    case hostKeyRejected
    case hostKeyMismatch(expected: String, actual: String)
    case channelRequestFailed
    case connectionClosed
    case timeout

    public var errorDescription: String? {
        switch self {
        case .connectFailed(let host, let port, let reason):
            return "无法连接到 \(host):\(port)，请检查地址、端口和网络。\n(\(reason))"
        case .authenticationFailed:
            return "认证失败：用户名、密码或私钥不正确"
        case .noSupportedAuthMethod:
            return "服务器不接受当前的认证方式"
        case .hostKeyRejected:
            return "已拒绝信任该主机"
        case .hostKeyMismatch(let expected, let actual):
            return "主机密钥与之前记录的不一致，可能存在中间人攻击，已中止连接。\n记录：\(expected)\n当前：\(actual)"
        case .channelRequestFailed:
            return "服务器拒绝了通道请求"
        case .connectionClosed:
            return "连接已被服务器关闭"
        case .timeout:
            return "操作超时"
        }
    }
}

/// 服务器主机公钥信息，用于 TOFU 校验。
public struct HostKeyInfo: Sendable, Equatable {
    /// 例如 `ssh-ed25519`
    public let keyType: String
    /// OpenSSH 风格指纹，例如 `SHA256:abc...`
    public let fingerprint: String

    init(_ key: NIOSSHPublicKey) {
        let openSSH = String(openSSHPublicKey: key)
        let parts = openSSH.split(separator: " ")
        keyType = parts.first.map(String.init) ?? "unknown"
        let blob = parts.count > 1 ? Data(base64Encoded: String(parts[1])) ?? Data() : Data()
        fingerprint = HostKeyInfo.fingerprint(ofKeyBlob: blob)
    }

    public init(keyType: String, fingerprint: String) {
        self.keyType = keyType
        self.fingerprint = fingerprint
    }

    static func fingerprint(ofKeyBlob blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }
}

/// 登录凭据（只在内存中使用，由 App 层从 Keychain 读取后传入）。
public enum SSHCredential {
    case password(String)
    case privateKey(NIOSSHPrivateKey)
}

/// 非交互命令的执行结果。
public struct SSHExecResult: Sendable, Equatable {
    public var exitStatus: Int?
    public var stdout: String
    public var stderr: String

    public var succeeded: Bool { exitStatus == 0 }
}
