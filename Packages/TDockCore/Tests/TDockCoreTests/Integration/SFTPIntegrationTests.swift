import Foundation
import XCTest
@testable import TDockCore

final class SFTPIntegrationTests: XCTestCase {
    func testBrowseUploadDownload() async throws {
        let config = try IntegrationConfig.load()
        let client = try await config.connect()
        defer { client.close() }
        let sftp = try await client.openSFTP()
        defer { sftp.close() }

        let home = try await sftp.realPath(".")
        XCTAssertTrue(home.hasPrefix("/"))

        // 用 exec 在服务器上建一个临时目录，测试结束删除。
        let dir = try await client.exec("mktemp -d").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(dir.isEmpty)
        defer { Task { _ = try? await client.exec("rm -rf '\(dir)'") } }

        // 不是块大小整数倍的随机内容，覆盖流水线与末块。
        let size = SFTPClient.chunkSize * 9 + 1234
        let original = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try original.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let progress = OutputCollector()
        try await sftp.upload(local, to: "\(dir)/blob.bin") { sent, _ in progress.append(Array("\(sent);".utf8)) }
        XCTAssertTrue(progress.text.hasSuffix("\(size);"))
        let uploadedSize = try await sftp.stat("\(dir)/blob.bin").size
        XCTAssertEqual(uploadedSize, UInt64(size))

        _ = try await client.exec("mkdir '\(dir)/sub'")
        let entries = try await sftp.listDirectory(dir)
        XCTAssertEqual(entries.map(\.name), ["sub", "blob.bin"], "目录在前")
        XCTAssertTrue(entries[0].isDirectory)

        let back = local.appendingPathExtension("back")
        defer { try? FileManager.default.removeItem(at: back) }
        try await sftp.download("\(dir)/blob.bin", to: back)
        XCTAssertEqual(try Data(contentsOf: back), original)

        let empty = local.appendingPathExtension("empty")
        defer { try? FileManager.default.removeItem(at: empty) }
        _ = try await client.exec("touch '\(dir)/empty'")
        try await sftp.download("\(dir)/empty", to: empty)
        XCTAssertEqual(try Data(contentsOf: empty).count, 0)
    }

    func testMissingPathReportsNoSuchFile() async throws {
        let config = try IntegrationConfig.load()
        let client = try await config.connect()
        defer { client.close() }
        let sftp = try await client.openSFTP()
        do {
            _ = try await sftp.listDirectory("/definitely/not/here")
            XCTFail("应当失败")
        } catch let error as SFTPError {
            XCTAssertEqual(error.code, SFTPError.Code.noSuchFile.rawValue)
        }
    }
}
