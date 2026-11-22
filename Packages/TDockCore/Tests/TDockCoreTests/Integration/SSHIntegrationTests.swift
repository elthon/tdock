import Crypto
import Foundation
import NIOSSH
import XCTest
@testable import TDockCore

final class SSHIntegrationTests: XCTestCase {
    func testTwoShellsShareOneConnection() async throws {
        let config = try IntegrationConfig.load()
        let client = try await config.connect()
        defer { client.close() }

        let outA = OutputCollector(), outB = OutputCollector()
        let shellA = try await client.openShell(cols: 80, rows: 24, onOutput: outA.append, onClose: { _ in })
        let shellB = try await client.openShell(cols: 80, rows: 24, onOutput: outB.append, onClose: { _ in })

        shellA.resize(cols: 100, rows: 30)
        try await Task.sleep(nanoseconds: 200_000_000)
        shellA.send(Array("echo A_$((40+2)); echo TERM=$TERM; stty size\n".utf8))
        shellB.send(Array("echo B_$((40+3))\n".utf8))
        try await outA.waitFor("A_42")
        try await outA.waitFor("TERM=xterm-256color")
        try await outA.waitFor("30 100")
        try await outB.waitFor("B_43")
        XCTAssertFalse(outA.text.contains("B_43"))
    }

    func testShellExitReportsStatus() async throws {
        let config = try IntegrationConfig.load()
        let client = try await config.connect()
        defer { client.close() }

        let closed = expectation(description: "closed")
        let status = OutputCollector()
        let shell = try await client.openShell(cols: 80, rows: 24, onOutput: { _ in }, onClose: { reason in
            status.append(Array("\(reason.exitStatus ?? -1)".utf8))
            closed.fulfill()
        })
        shell.send(Array("exit 7\n".utf8))
        await fulfillment(of: [closed], timeout: 10)
        XCTAssertEqual(status.text, "7")
        XCTAssertTrue(client.isActive, "关闭一个通道不应断开整条连接")
    }

    func testExecCollectsOutputAndStatus() async throws {
        let config = try IntegrationConfig.load()
        let client = try await config.connect()
        defer { client.close() }

        let ok = try await client.exec("echo out; echo err >&2; exit 3")
        XCTAssertEqual(ok.stdout, "out\n")
        XCTAssertEqual(ok.stderr, "err\n")
        XCTAssertEqual(ok.exitStatus, 3)

        // 多条 exec 可并发复用同一连接
        async let a = client.exec("echo 1")
        async let b = client.exec("echo 2")
        let (ra, rb) = try await (a, b)
        XCTAssertEqual(ra.stdout + rb.stdout, "1\n2\n")
    }

    func testPTYExecRunsCommand() async throws {
        let config = try IntegrationConfig.load()
        let client = try await config.connect()
        defer { client.close() }

        let out = OutputCollector()
        _ = try await client.openShell(cols: 80, rows: 24, command: "echo PTY_EXEC_$((1+1))", onOutput: out.append, onClose: { _ in })
        try await out.waitFor("PTY_EXEC_2")
    }

    func testUnauthorizedKeyFails() async throws {
        let config = try IntegrationConfig.load()
        let stranger = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        do {
            _ = try await config.connect(credential: .privateKey(stranger))
            XCTFail("应当认证失败")
        } catch {
            XCTAssertEqual(error as? SSHSessionError, .authenticationFailed)
        }
    }

    func testPasswordOnKeyOnlyServer() async throws {
        let config = try IntegrationConfig.load()
        do {
            _ = try await config.connect(credential: .password("not-a-real-password"))
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error as? SSHSessionError, .noSupportedAuthMethod)
        }
    }

    func testHostKeyMismatchAborts() async throws {
        let config = try IntegrationConfig.load()
        do {
            _ = try await config.connect(expectedFingerprint: "SHA256:not-the-right-one")
            XCTFail("应当拒绝")
        } catch {
            guard case .hostKeyMismatch = error as? SSHSessionError else {
                return XCTFail("意外错误：\(error)")
            }
        }
    }

    func testConnectionRefused() async throws {
        let config = try IntegrationConfig.load()
        do {
            _ = try await SSHClient.connect(host: "127.0.0.1", port: 1, username: config.user,
                                            credential: .password("x")) { _ in }
            XCTFail("应当失败")
        } catch {
            guard case .connectFailed = error as? SSHSessionError else {
                return XCTFail("意外错误：\(error)")
            }
        }
    }

    func testDisconnectHandlerFires() async throws {
        let config = try IntegrationConfig.load()
        let client = try await config.connect()
        let fired = expectation(description: "disconnect")
        client.onDisconnect { _ in fired.fulfill() }
        client.close()
        await fulfillment(of: [fired], timeout: 5)
    }
}

final class GeneratedKeyLoginTests: XCTestCase {
    /// App 内生成的密钥加入 authorized_keys 后可以登录。
    func testLoginWithGeneratedKey() async throws {
        let config = try IntegrationConfig.load()
        guard let path = ProcessInfo.processInfo.environment["TDOCK_IT_AUTHORIZED_KEYS"] else {
            throw XCTSkip("未设置 TDOCK_IT_AUTHORIZED_KEYS")
        }
        let pair = OpenSSHKeyGenerator.ed25519(comment: "tdock-it-generated")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((pair.publicKey + "\n").utf8))
        try handle.close()

        let client = try await config.connect(credential: .privateKey(OpenSSHPrivateKey.parse(pair.privateKeyPEM)))
        defer { client.close() }
        let result = try await client.exec("echo generated-ok")
        XCTAssertEqual(result.stdout, "generated-ok\n")
    }
}

final class DeployKeyIntegrationTests: XCTestCase {
    /// 内置 ssh-copy-id：经已登录的连接部署公钥后，可用该密钥登录；重复部署不产生重复行。
    func testDeployPublicKeyThenLogin() async throws {
        let config = try IntegrationConfig.load()
        guard let path = ProcessInfo.processInfo.environment["TDOCK_IT_AUTHORIZED_KEYS"] else {
            throw XCTSkip("未设置 TDOCK_IT_AUTHORIZED_KEYS")
        }
        let pair = OpenSSHKeyGenerator.ed25519(comment: "tdock-deploy")
        let newKey = try SSHCredential.privateKey(OpenSSHPrivateKey.parse(pair.privateKeyPEM))

        // 部署前不能登录。
        do {
            let client = try await config.connect(credential: newKey)
            client.close()
            XCTFail("部署前不应能登录")
        } catch {}

        let admin = try await config.connect()
        defer { admin.close() }
        let first = try await AuthorizedKeysInstaller.install(publicKey: pair.publicKey, on: admin, authorizedKeysPath: path)
        XCTAssertEqual(first, .installed)
        let again = try await AuthorizedKeysInstaller.install(publicKey: pair.publicKey, on: admin, authorizedKeysPath: path)
        XCTAssertEqual(again, .alreadyPresent)
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(contents.components(separatedBy: pair.publicKey).count - 1, 1, "只追加一次")

        let client = try await config.connect(credential: newKey)
        defer { client.close() }
        let result = try await client.exec("echo deployed-ok")
        XCTAssertEqual(result.stdout, "deployed-ok\n")
    }
}
