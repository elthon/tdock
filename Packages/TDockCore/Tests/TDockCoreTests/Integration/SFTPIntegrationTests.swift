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

    func testFileManagementOperations() async throws {
        let config = try IntegrationConfig.load()
        let client = try await config.connect()
        defer { client.close() }
        let sftp = try await client.openSFTP()
        defer { sftp.close() }
        let dir = try await client.exec("mktemp -d").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { Task { _ = try? await client.exec("rm -rf '\(dir)'") } }

        try await sftp.makeDirectory("\(dir)/新 文件夹")
        let created = try await sftp.stat("\(dir)/新 文件夹")
        XCTAssertTrue(created.isDirectory)

        _ = try await client.exec("echo hi > '\(dir)/a.txt'")
        try await sftp.rename("\(dir)/a.txt", to: "\(dir)/新 文件夹/b.txt")
        let names = try await sftp.listDirectory("\(dir)/新 文件夹").map(\.name)
        XCTAssertEqual(names, ["b.txt"])

        try await sftp.setPermissions("\(dir)/新 文件夹/b.txt", 0o600)
        let attrs = try await sftp.stat("\(dir)/新 文件夹/b.txt")
        XCTAssertEqual(attrs.permissions.map { $0 & 0o7777 }, 0o600)
        XCTAssertTrue(attrs.isRegularFile, "setstat 只改权限位，不改文件类型")
        let mode = try await client.exec("stat -c %a '\(dir)/新 文件夹/b.txt'").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(mode, "600")

        // 非空目录不能直接删除（SFTP v3 语义）。
        do {
            try await sftp.removeDirectory("\(dir)/新 文件夹")
            XCTFail("非空目录应删除失败")
        } catch is SFTPError {}

        try await sftp.remove("\(dir)/新 文件夹/b.txt")
        try await sftp.removeDirectory("\(dir)/新 文件夹")
        let remaining = try await sftp.listDirectory(dir)
        XCTAssertTrue(remaining.isEmpty)

        do {
            try await sftp.remove("\(dir)/missing")
            XCTFail("删除不存在的文件应失败")
        } catch let error as SFTPError {
            XCTAssertEqual(error.code, SFTPError.Code.noSuchFile.rawValue)
        }
    }

    func testDownloadCanBeCancelled() async throws {
        let config = try IntegrationConfig.load()
        let client = try await config.connect()
        defer { client.close() }
        let sftp = try await client.openSFTP()
        defer { sftp.close() }
        let dir = try await client.exec("mktemp -d").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { Task { _ = try? await client.exec("rm -rf '\(dir)'") } }
        _ = try await client.exec("truncate -s 1G '\(dir)/big.bin'") // 稀疏文件，不占磁盘

        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local) }
        let started = OutputCollector()
        let task = Task {
            try await sftp.download("\(dir)/big.bin", to: local) { done, _ in
                if done > 0 { started.append([1]) }
            }
        }
        try await started.waitFor("\u{1}")
        task.cancel()
        do {
            try await task.value
            XCTFail("应当被取消")
        } catch is CancellationError {}
        let partial = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertLessThan(partial, 1_073_741_824, "取消后不会继续下载")

        // 取消后同一个 SFTP 会话仍可继续使用。
        let entries = try await sftp.listDirectory(dir)
        XCTAssertEqual(entries.map(\.name), ["big.bin"])
    }
}
