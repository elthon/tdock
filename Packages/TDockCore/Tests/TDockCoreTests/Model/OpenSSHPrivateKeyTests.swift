import Crypto
import Foundation
import NIOSSH
import XCTest
@testable import TDockCore

/// 测试用私钥均在运行时生成，仓库中不存放任何密钥。
final class OpenSSHPrivateKeyTests: XCTestCase {
    func testParsesEd25519() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pub = Array(key.publicKey.rawRepresentation)
        let pem = OpenSSHFixture.pem(
            keyType: "ssh-ed25519",
            privateFields: [.string(pub), .string(Array(key.rawRepresentation) + pub)]
        )
        let parsed = try OpenSSHPrivateKey.parse(pem)
        XCTAssertEqual(parsed.publicKey, NIOSSHPrivateKey(ed25519Key: key).publicKey)
    }

    func testParsesECDSAP256() throws {
        let key = P256.Signing.PrivateKey()
        // mpint：最高位为 1 时前补 0x00，用于覆盖去前导零逻辑。
        var d = Array(key.rawRepresentation)
        if d[0] & 0x80 != 0 { d.insert(0, at: 0) }
        let pem = OpenSSHFixture.pem(
            keyType: "ecdsa-sha2-nistp256",
            privateFields: [
                .string(Array("nistp256".utf8)),
                .string(Array(key.publicKey.x963Representation)),
                .string(d),
            ]
        )
        let parsed = try OpenSSHPrivateKey.parse(pem)
        XCTAssertEqual(parsed.publicKey, NIOSSHPrivateKey(p256Key: key).publicKey)
    }

    func testParsesECDSAP384() throws {
        let key = P384.Signing.PrivateKey()
        let pem = OpenSSHFixture.pem(
            keyType: "ecdsa-sha2-nistp384",
            privateFields: [
                .string(Array("nistp384".utf8)),
                .string(Array(key.publicKey.x963Representation)),
                .string(Array(key.rawRepresentation)),
            ]
        )
        let parsed = try OpenSSHPrivateKey.parse(pem)
        XCTAssertEqual(parsed.publicKey, NIOSSHPrivateKey(p384Key: key).publicKey)
    }

    func testRejectsEncryptedKey() {
        let pem = OpenSSHFixture.pem(keyType: "ssh-ed25519", privateFields: [], cipher: "aes256-ctr")
        XCTAssertThrowsError(try OpenSSHPrivateKey.parse(pem)) {
            XCTAssertEqual($0 as? OpenSSHKeyError, .encryptedKeyUnsupported)
        }
    }

    func testRejectsRSA() {
        let pem = OpenSSHFixture.pem(keyType: "ssh-rsa", privateFields: [])
        XCTAssertThrowsError(try OpenSSHPrivateKey.parse(pem)) {
            XCTAssertEqual($0 as? OpenSSHKeyError, .unsupportedKeyType("ssh-rsa"))
        }
    }

    func testRejectsLegacyPEM() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----"
        XCTAssertThrowsError(try OpenSSHPrivateKey.parse(pem)) {
            XCTAssertEqual($0 as? OpenSSHKeyError, .legacyPEMFormat)
        }
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try OpenSSHPrivateKey.parse("hello")) {
            XCTAssertEqual($0 as? OpenSSHKeyError, .notOpenSSHFormat)
        }
        let truncated = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEA\n-----END OPENSSH PRIVATE KEY-----"
        XCTAssertThrowsError(try OpenSSHPrivateKey.parse(truncated)) {
            XCTAssertEqual($0 as? OpenSSHKeyError, .invalidFormat)
        }
    }

    func testFingerprintFormat() {
        let fp = HostKeyInfo.fingerprint(ofKeyBlob: Data([1, 2, 3]))
        XCTAssertTrue(fp.hasPrefix("SHA256:"))
        XCTAssertFalse(fp.contains("="))
        XCTAssertEqual(fp.count, "SHA256:".count + 43)
    }

    func testProfileValidation() {
        var profile = ServerProfile(host: "example.com", username: "me")
        XCTAssertNil(profile.validationError())
        XCTAssertEqual(profile.displayName, "me@example.com")
        profile.port = 0
        XCTAssertNotNil(profile.validationError())
    }
}

/// 按 openssh-key-v1 格式编码测试私钥。
enum OpenSSHFixture {
    enum Field {
        case string([UInt8])
    }

    static func pem(keyType: String, privateFields: [Field], cipher: String = "none") -> String {
        var priv = [UInt8]()
        let check = UInt32.random(in: .min ... .max)
        priv += uint32(check) + uint32(check)
        priv += string(Array(keyType.utf8))
        for case .string(let bytes) in privateFields { priv += string(bytes) }
        priv += string(Array("test".utf8)) // comment
        var pad: UInt8 = 1
        while priv.count % 8 != 0 { priv.append(pad); pad += 1 }

        var blob = Array("openssh-key-v1\0".utf8)
        blob += string(Array(cipher.utf8))
        blob += string(Array((cipher == "none" ? "none" : "bcrypt").utf8))
        blob += string([])
        blob += uint32(1)
        blob += string(Array(keyType.utf8)) // 公钥段内容测试中不使用
        blob += string(priv)

        let body = Data(blob).base64EncodedString(options: .lineLength64Characters)
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(body)\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    private static func uint32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    private static func string(_ bytes: [UInt8]) -> [UInt8] {
        uint32(UInt32(bytes.count)) + bytes
    }
}
