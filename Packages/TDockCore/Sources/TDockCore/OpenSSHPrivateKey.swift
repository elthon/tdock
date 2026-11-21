import Crypto
import Foundation
import NIOSSH

public enum OpenSSHKeyError: Error, Equatable, LocalizedError {
    case notOpenSSHFormat
    case legacyPEMFormat
    case invalidFormat
    case encryptedKeyUnsupported
    case multipleKeysUnsupported
    case unsupportedKeyType(String)

    public var errorDescription: String? {
        switch self {
        case .notOpenSSHFormat:
            return "无法识别的私钥格式，请粘贴以 -----BEGIN OPENSSH PRIVATE KEY----- 开头的私钥"
        case .legacyPEMFormat:
            return "暂不支持旧版 PEM 私钥，请用 `ssh-keygen -p -f <密钥文件>` 转为 OpenSSH 格式"
        case .invalidFormat:
            return "私钥内容已损坏或不完整"
        case .encryptedKeyUnsupported:
            return "暂不支持带密码（passphrase）的私钥"
        case .multipleKeysUnsupported:
            return "私钥文件中包含多个密钥，暂不支持"
        case .unsupportedKeyType(let type):
            return "暂不支持的密钥类型：\(type)（目前支持 Ed25519 和 ECDSA）"
        }
    }
}

/// 解析 OpenSSH 私钥格式（`openssh-key-v1`）。
///
/// 支持未加密的 ssh-ed25519、ecdsa-sha2-nistp256/384/521。
public enum OpenSSHPrivateKey {
    private static let beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let endMarker = "-----END OPENSSH PRIVATE KEY-----"
    private static let magic = Array("openssh-key-v1\0".utf8)

    public static func parse(_ text: String) throws -> NIOSSHPrivateKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let begin = trimmed.range(of: beginMarker),
              let end = trimmed.range(of: endMarker, range: begin.upperBound..<trimmed.endIndex)
        else {
            if trimmed.contains("-----BEGIN") && trimmed.contains("PRIVATE KEY-----") {
                throw OpenSSHKeyError.legacyPEMFormat
            }
            throw OpenSSHKeyError.notOpenSSHFormat
        }
        let base64 = trimmed[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(base64)) else {
            throw OpenSSHKeyError.invalidFormat
        }
        return try parse(blob: Array(data))
    }

    static func parse(blob: [UInt8]) throws -> NIOSSHPrivateKey {
        guard blob.starts(with: magic) else { throw OpenSSHKeyError.invalidFormat }
        var reader = SSHWireReader(blob[magic.count...])

        let cipher = try reader.readStringUTF8()
        let kdf = try reader.readStringUTF8()
        _ = try reader.readString() // kdf options
        guard cipher == "none", kdf == "none" else { throw OpenSSHKeyError.encryptedKeyUnsupported }
        guard try reader.readUInt32() == 1 else { throw OpenSSHKeyError.multipleKeysUnsupported }
        _ = try reader.readString() // public key blob

        var priv = SSHWireReader(try reader.readString())
        let check1 = try priv.readUInt32()
        let check2 = try priv.readUInt32()
        guard check1 == check2 else { throw OpenSSHKeyError.invalidFormat }

        let keyType = try priv.readStringUTF8()
        switch keyType {
        case "ssh-ed25519":
            _ = try priv.readString() // public key (32 bytes)
            let secret = try priv.readString() // seed(32) || public(32)
            guard secret.count == 64 else { throw OpenSSHKeyError.invalidFormat }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32))
            return NIOSSHPrivateKey(ed25519Key: key)

        case "ecdsa-sha2-nistp256":
            let d = try readECDSAScalar(&priv, length: 32)
            return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: d))

        case "ecdsa-sha2-nistp384":
            let d = try readECDSAScalar(&priv, length: 48)
            return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: d))

        case "ecdsa-sha2-nistp521":
            let d = try readECDSAScalar(&priv, length: 66)
            return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: d))

        default:
            throw OpenSSHKeyError.unsupportedKeyType(keyType)
        }
    }

    /// ECDSA 私钥段：curve name, Q, d(mpint)。返回定长大端 d。
    private static func readECDSAScalar(_ reader: inout SSHWireReader, length: Int) throws -> [UInt8] {
        _ = try reader.readString() // curve name
        _ = try reader.readString() // public point Q
        var d = Array(try reader.readString().drop(while: { $0 == 0 }))
        guard d.count <= length else { throw OpenSSHKeyError.invalidFormat }
        d.insert(contentsOf: repeatElement(0, count: length - d.count), at: 0)
        return d
    }
}

/// SSH 线格式（RFC 4251）最小读取器。
struct SSHWireReader {
    private var bytes: ArraySlice<UInt8>

    init<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        self.bytes = ArraySlice(bytes)
    }

    mutating func readUInt32() throws -> UInt32 {
        guard bytes.count >= 4 else { throw OpenSSHKeyError.invalidFormat }
        let value = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        bytes = bytes.dropFirst(4)
        return value
    }

    mutating func readString() throws -> ArraySlice<UInt8> {
        let length = Int(try readUInt32())
        guard bytes.count >= length else { throw OpenSSHKeyError.invalidFormat }
        let value = bytes.prefix(length)
        bytes = bytes.dropFirst(length)
        return value
    }

    mutating func readStringUTF8() throws -> String {
        guard let s = String(bytes: try readString(), encoding: .utf8) else {
            throw OpenSSHKeyError.invalidFormat
        }
        return s
    }
}
