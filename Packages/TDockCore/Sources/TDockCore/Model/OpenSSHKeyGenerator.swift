import Crypto
import Foundation
import NIOSSH

/// App 内生成的密钥对。
public struct GeneratedKeyPair: Sendable {
    /// OpenSSH 格式私钥（未加密）——只应写入 Keychain，不得落盘或打印。
    public let privateKeyPEM: String
    /// authorized_keys 格式公钥：`ssh-ed25519 AAAA… 注释`
    public let publicKey: String
    /// 公钥指纹 `SHA256:…`
    public let fingerprint: String
}

/// 导入私钥后得到的公开信息。
public struct ImportedKeyInfo: Sendable, Equatable {
    /// 例如 `ssh-ed25519`、`ecdsa-sha2-nistp256`
    public let keyType: String
    /// authorized_keys 格式公钥
    public let publicKey: String
    public let fingerprint: String
}

public enum OpenSSHKeyGenerator {
    /// 生成 Ed25519 密钥对。
    public static func ed25519(comment: String) -> GeneratedKeyPair {
        let key = Curve25519.Signing.PrivateKey()
        return encode(key, comment: comment)
    }

    static func encode(_ key: Curve25519.Signing.PrivateKey, comment: String) -> GeneratedKeyPair {
        let keyType = Array("ssh-ed25519".utf8)
        let publicBytes = Array(key.publicKey.rawRepresentation)
        let seed = Array(key.rawRepresentation)

        var publicBlob = SSHWireWriter()
        publicBlob.string(keyType)
        publicBlob.string(publicBytes)

        var privateSection = SSHWireWriter()
        let check = UInt32.random(in: .min ... .max)
        privateSection.uint32(check)
        privateSection.uint32(check)
        privateSection.string(keyType)
        privateSection.string(publicBytes)
        privateSection.string(seed + publicBytes)
        privateSection.string(Array(comment.utf8))
        var pad: UInt8 = 1
        while privateSection.bytes.count % 8 != 0 {
            privateSection.bytes.append(pad)
            pad += 1
        }

        var blob = SSHWireWriter()
        blob.bytes = Array("openssh-key-v1\0".utf8)
        blob.string(Array("none".utf8)) // cipher
        blob.string(Array("none".utf8)) // kdf
        blob.string([])                  // kdf options
        blob.uint32(1)                   // number of keys
        blob.string(publicBlob.bytes)
        blob.string(privateSection.bytes)

        let base64 = Data(blob.bytes).base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 70).map { offset -> Substring in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            return base64[start..<end]
        }
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + lines.joined(separator: "\n")
            + "\n-----END OPENSSH PRIVATE KEY-----\n"

        let publicLine = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return GeneratedKeyPair(
            privateKeyPEM: pem,
            publicKey: trimmedComment.isEmpty ? publicLine : "\(publicLine) \(trimmedComment)",
            fingerprint: HostKeyInfo.fingerprint(ofKeyBlob: Data(publicBlob.bytes))
        )
    }

    /// 导入已有私钥：校验（未加密 Ed25519 / ECDSA）并推导公钥行与指纹。私钥本身由调用方写入 Keychain。
    public static func importedKeyInfo(privateKeyPEM pem: String, comment: String) throws -> ImportedKeyInfo {
        let key = try OpenSSHPrivateKey.parse(pem)
        let line = String(openSSHPublicKey: key.publicKey)
        let parts = line.split(separator: " ")
        let blob = parts.count > 1 ? Data(base64Encoded: String(parts[1])) ?? Data() : Data()
        let sanitized = AuthorizedKeysInstaller.sanitizeComment(comment)
        return ImportedKeyInfo(
            keyType: parts.first.map(String.init) ?? "",
            publicKey: sanitized.isEmpty ? line : "\(line) \(sanitized)",
            fingerprint: HostKeyInfo.fingerprint(ofKeyBlob: blob)
        )
    }

    /// 从私钥推导 authorized_keys 公钥行。
    public static func publicKeyLine(forPrivateKeyPEM pem: String, comment: String = "") throws -> String {
        let key = try OpenSSHPrivateKey.parse(pem)
        let line = String(openSSHPublicKey: key.publicKey)
        return comment.isEmpty ? line : "\(line) \(comment)"
    }
}

/// SSH 线格式（RFC 4251）最小写入器。
struct SSHWireWriter {
    var bytes: [UInt8] = []

    mutating func uint32(_ value: UInt32) {
        bytes += [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    mutating func string(_ value: [UInt8]) {
        uint32(UInt32(value.count))
        bytes += value
    }
}
