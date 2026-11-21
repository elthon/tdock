import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import TDockCore

/// 集成测试配置，来自 Scripts/integration-test.sh 设置的环境变量；未设置时跳过。
struct IntegrationConfig {
    let host: String
    let port: Int
    let user: String
    let keyPEM: String
    let hostFingerprint: String

    static func load() throws -> IntegrationConfig {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["TDOCK_IT_HOST"], let port = env["TDOCK_IT_PORT"].flatMap(Int.init),
              let user = env["TDOCK_IT_USER"], let keyPath = env["TDOCK_IT_KEY"],
              let fingerprint = env["TDOCK_IT_HOST_FINGERPRINT"]
        else {
            throw XCTSkip("未设置 TDOCK_IT_* 环境变量，跳过集成测试（见 Scripts/integration-test.sh）")
        }
        return IntegrationConfig(
            host: host, port: port, user: user,
            keyPEM: try String(contentsOfFile: keyPath, encoding: .utf8),
            hostFingerprint: fingerprint
        )
    }

    func connect(credential: SSHCredential? = nil, expectedFingerprint: String? = nil) async throws -> SSHClient {
        let expected = expectedFingerprint ?? hostFingerprint
        return try await SSHClient.connect(
            host: host, port: port, username: user,
            credential: try credential ?? .privateKey(OpenSSHPrivateKey.parse(keyPEM))
        ) { info in
            guard info.fingerprint == expected else {
                throw SSHSessionError.hostKeyMismatch(expected: expected, actual: info.fingerprint)
            }
        }
    }
}

/// 线程安全地收集终端输出，并可等待某段文本出现。
final class OutputCollector: @unchecked Sendable {
    private let box = NIOLockedValueBox<[UInt8]>([])

    func append(_ bytes: [UInt8]) {
        box.withLockedValue { $0.append(contentsOf: bytes) }
    }

    var text: String { String(decoding: box.withLockedValue { $0 }, as: UTF8.self) }

    func waitFor(_ needle: String, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !text.contains(needle) {
            if Date() > deadline {
                XCTFail("等待输出 \(needle.debugDescription) 超时；实际输出：\(text.suffix(400).debugDescription)")
                throw SSHSessionError.timeout
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
