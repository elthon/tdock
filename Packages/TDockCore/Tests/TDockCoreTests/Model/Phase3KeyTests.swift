import Crypto
import Foundation
import NIOSSH
import XCTest
@testable import TDockCore

final class Phase3KeyTests: XCTestCase {
    func testImportedKeyInfoEd25519MatchesGenerator() throws {
        let pair = OpenSSHKeyGenerator.ed25519(comment: "x")
        let info = try OpenSSHKeyGenerator.importedKeyInfo(privateKeyPEM: pair.privateKeyPEM, comment: "my laptop")
        XCTAssertEqual(info.keyType, "ssh-ed25519")
        XCTAssertEqual(info.fingerprint, pair.fingerprint)
        XCTAssertEqual(info.publicKey, pair.publicKey.replacingOccurrences(of: " x", with: " mylaptop"))
    }

    func testImportedKeyInfoECDSA() throws {
        let key = P256.Signing.PrivateKey()
        var d = Array(key.rawRepresentation)
        if d[0] & 0x80 != 0 { d.insert(0, at: 0) }
        let pem = OpenSSHFixture.pem(keyType: "ecdsa-sha2-nistp256", privateFields: [
            .string(Array("nistp256".utf8)), .string(Array(key.publicKey.x963Representation)), .string(d),
        ])
        let info = try OpenSSHKeyGenerator.importedKeyInfo(privateKeyPEM: pem, comment: "")
        XCTAssertEqual(info.keyType, "ecdsa-sha2-nistp256")
        XCTAssertEqual(info.publicKey, String(openSSHPublicKey: NIOSSHPrivateKey(p256Key: key).publicKey))
        XCTAssertTrue(info.fingerprint.hasPrefix("SHA256:"))
        XCTAssertThrowsError(try OpenSSHKeyGenerator.importedKeyInfo(privateKeyPEM: "not a key", comment: ""))
    }

    func testNormalizeRejectsUnsafeKeys() throws {
        let pair = OpenSSHKeyGenerator.ed25519(comment: "")
        let (body, line) = try AuthorizedKeysInstaller.normalize(publicKey: "  \(pair.publicKey) me@phone; rm -rf ~ \n")
        XCTAssertEqual(body, pair.publicKey)
        XCTAssertEqual(line, "\(pair.publicKey) me@phonerm-rf", "注释中的危险字符被去掉")
        for bad in [
            "ssh-rsa AAAAB3NzaC1yc2E", // 不支持 RSA
            "ssh-ed25519",
            "ssh-ed25519 AAAA'$(reboot)'",
            "ssh-ed25519 AAAA\nssh-ed25519 AAAA",
            "ssh-ed25519 !!!!",
        ] {
            XCTAssertThrowsError(try AuthorizedKeysInstaller.normalize(publicKey: bad), bad)
        }
    }

    func testOutcomeParsing() throws {
        XCTAssertEqual(try AuthorizedKeysInstaller.outcome(of: SSHExecResult(exitStatus: 0, stdout: "TDOCK_KEY_INSTALLED\n", stderr: "")), .installed)
        XCTAssertEqual(try AuthorizedKeysInstaller.outcome(of: SSHExecResult(exitStatus: 0, stdout: "TDOCK_KEY_PRESENT\n", stderr: "")), .alreadyPresent)
        XCTAssertThrowsError(try AuthorizedKeysInstaller.outcome(of: SSHExecResult(exitStatus: 1, stdout: "", stderr: "Permission denied"))) {
            XCTAssertEqual($0 as? AuthorizedKeysInstaller.InstallError, .failed("Permission denied"))
        }
    }

    /// 在本机 /bin/sh 上实际执行生成的脚本（HOME 指向临时目录）：创建目录与文件、权限、幂等、补换行。
    func testScriptRunsWithPOSIXShell() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".ssh/authorized_keys")

        let first = OpenSSHKeyGenerator.ed25519(comment: "first")
        XCTAssertEqual(try runInstaller(first.publicKey, home: home), "TDOCK_KEY_INSTALLED")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), first.publicKey + "\n")
        let dirMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)

        // 同一把公钥（注释不同）再次部署：不重复追加。
        let sameKeyOtherComment = first.publicKey.replacingOccurrences(of: " first", with: " again")
        XCTAssertEqual(try runInstaller(sameKeyOtherComment, home: home), "TDOCK_KEY_PRESENT")

        // 已有文件没有以换行结尾：先补换行再追加。
        try (first.publicKey).write(to: file, atomically: true, encoding: .utf8)
        let second = OpenSSHKeyGenerator.ed25519(comment: "second")
        XCTAssertEqual(try runInstaller(second.publicKey, home: home), "TDOCK_KEY_INSTALLED")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), first.publicKey + "\n" + second.publicKey + "\n")
    }

    func testScriptWithCustomPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tdock it's \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("keys")
        let pair = OpenSSHKeyGenerator.ed25519(comment: "")
        XCTAssertEqual(try runInstaller(pair.publicKey, home: dir, path: file.path), "TDOCK_KEY_INSTALLED")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), pair.publicKey + "\n")
    }

    private func runInstaller(_ publicKey: String, home: URL, path: String? = nil) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: "/bin/sh") else { throw XCTSkip("没有 /bin/sh") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", try AuthorizedKeysInstaller.command(publicKey: publicKey, authorizedKeysPath: path)]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
