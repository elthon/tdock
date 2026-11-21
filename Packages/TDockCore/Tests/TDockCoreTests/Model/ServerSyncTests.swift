import Foundation
import XCTest
@testable import TDockCore

final class ServerSyncTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func profile(_ name: String, at offset: TimeInterval, id: UUID = UUID()) -> ServerProfile {
        ServerProfile(id: id, name: name, host: "\(name).example", username: "u", updatedAt: t0.addingTimeInterval(offset))
    }

    func testNewerEditWins() {
        let id = UUID()
        let local = SyncDocument(servers: [profile("old", at: 0, id: id)])
        let remote = SyncDocument(servers: [profile("new", at: 10, id: id)])
        XCTAssertEqual(ServerSync.merge(local: local, remote: remote, now: t0).servers.map(\.name), ["new"])
        XCTAssertEqual(ServerSync.merge(local: remote, remote: local, now: t0).servers.map(\.name), ["new"])
    }

    func testUnionKeepsLocalOrderThenRemote() {
        let a = profile("a", at: 0), b = profile("b", at: 0), c = profile("c", at: 0)
        let merged = ServerSync.merge(local: SyncDocument(servers: [b, a]), remote: SyncDocument(servers: [a, c]), now: t0)
        XCTAssertEqual(merged.servers.map(\.name), ["b", "a", "c"])
    }

    func testDeletionPropagates() {
        let a = profile("a", at: 0)
        let local = SyncDocument(servers: [a])
        let remote = SyncDocument(servers: [], tombstones: [a.id: t0.addingTimeInterval(5)])
        let merged = ServerSync.merge(local: local, remote: remote, now: t0)
        XCTAssertTrue(merged.servers.isEmpty)
        XCTAssertNotNil(merged.tombstones[a.id])
    }

    func testEditAfterDeletionResurrects() {
        let id = UUID()
        let local = SyncDocument(servers: [profile("edited", at: 20, id: id)])
        let remote = SyncDocument(tombstones: [id: t0.addingTimeInterval(10)])
        let merged = ServerSync.merge(local: local, remote: remote, now: t0)
        XCTAssertEqual(merged.servers.map(\.name), ["edited"])
        XCTAssertNil(merged.tombstones[id])
    }

    func testOldTombstonesArePruned() {
        let doc = SyncDocument(tombstones: [UUID(): t0])
        let later = t0.addingTimeInterval(ServerSync.tombstoneLifetime + 1)
        XCTAssertTrue(ServerSync.merge(local: doc, remote: SyncDocument(), now: later).tombstones.isEmpty)
    }

    func testMergeIsIdempotent() {
        let doc = SyncDocument(servers: [profile("a", at: 1), profile("b", at: 2)], tombstones: [UUID(): t0])
        XCTAssertEqual(ServerSync.merge(local: doc, remote: doc, now: t0), doc)
    }

    func testEncodingRoundTripHasNoSecrets() throws {
        let doc = SyncDocument(servers: [profile("a", at: 0)], tombstones: [UUID(): t0])
        let data = try doc.encoded()
        XCTAssertEqual(try SyncDocument.decode(data), doc)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("password\":\""), "同步文档中不应出现密码字段")
    }
}
