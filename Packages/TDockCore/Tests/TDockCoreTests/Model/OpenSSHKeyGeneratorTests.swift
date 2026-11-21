import Foundation
import NIOSSH
import XCTest
@testable import TDockCore

final class OpenSSHKeyGeneratorTests: XCTestCase {
    func testGeneratedKeyRoundTrips() throws {
        let pair = OpenSSHKeyGenerator.ed25519(comment: "tdock@iphone")
        XCTAssertTrue(pair.privateKeyPEM.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        XCTAssertTrue(pair.publicKey.hasPrefix("ssh-ed25519 AAAA"))
        XCTAssertTrue(pair.publicKey.hasSuffix(" tdock@iphone"))
        XCTAssertTrue(pair.fingerprint.hasPrefix("SHA256:"))

        let parsed = try OpenSSHPrivateKey.parse(pair.privateKeyPEM)
        let publicPart = pair.publicKey.split(separator: " ").prefix(2).joined(separator: " ")
        XCTAssertEqual(parsed.publicKey, try NIOSSHPublicKey(openSSHPublicKey: publicPart))
        XCTAssertEqual(try OpenSSHKeyGenerator.publicKeyLine(forPrivateKeyPEM: pair.privateKeyPEM), publicPart)
    }

    func testKeysAreUnique() {
        XCTAssertNotEqual(OpenSSHKeyGenerator.ed25519(comment: "").publicKey,
                          OpenSSHKeyGenerator.ed25519(comment: "").publicKey)
    }

    /// 用真实的 ssh-keygen 校验生成的私钥格式（存在 ssh-keygen 时）。
    func testOpenSSHAcceptsGeneratedKey() throws {
        let keygen = ["/usr/bin/ssh-keygen", "/opt/homebrew/bin/ssh-keygen", "/usr/local/bin/ssh-keygen"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let keygen else { throw XCTSkip("未找到 ssh-keygen") }

        let pair = OpenSSHKeyGenerator.ed25519(comment: "check")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("key")
        try pair.privateKeyPEM.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        let output = try run(keygen, ["-y", "-f", file.path])
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), pair.publicKey)
        let fingerprint = try run(keygen, ["-l", "-f", file.path])
        XCTAssertTrue(fingerprint.contains(pair.fingerprint), fingerprint)
    }

    private func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, output)
        return output
    }
}
