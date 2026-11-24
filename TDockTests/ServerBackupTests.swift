import Foundation
import TDockCore
import XCTest
@testable import TDock

final class ServerBackupTests: XCTestCase {
    private func profile(id: UUID = UUID(), name: String = "Test") -> ServerProfile {
        ServerProfile(id: id, name: name, host: "127.0.0.1", username: "test",
                      group: "Work", pinned: true, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testRoundTripPreservesConfigurationWithoutKeyLibraryReference() throws {
        var server = profile()
        server.authMethod = .privateKey
        server.keyID = UUID()
        server.transport = .mosh
        server.portForwards = [PortForwardRule(localPort: 8080, remoteHost: "localhost", remotePort: 80)]
        let data = try ServerBackup(servers: [server]).encoded()
        let restored = try ServerBackup.decode(data)
        var expected = server
        expected.keyID = nil
        XCTAssertEqual(restored.servers, [expected])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["tombstones"])
        let values = try XCTUnwrap(json["servers"] as? [[String: Any]])
        XCTAssertNil(values[0]["keyID"])
        XCTAssertNil(values[0]["password"])
        XCTAssertNil(values[0]["privateKey"])
    }

    func testInvalidFilesAreRejectedBeforePlanning() throws {
        XCTAssertThrowsError(try ServerBackup.decode(Data("not json".utf8)))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ServerBackup(servers: [profile()]).encoded()) as? [String: Any])
        json["version"] = 99
        XCTAssertThrowsError(try ServerBackup.decode(JSONSerialization.data(withJSONObject: json)))
        json["version"] = 1
        json["format"] = "unrelated.backup"
        XCTAssertThrowsError(try ServerBackup.decode(JSONSerialization.data(withJSONObject: json)))
    }

    func testOversizedDuplicateAndInvalidConfigurationsAreRejected() throws {
        XCTAssertThrowsError(try ServerBackup.decode(Data(repeating: 32, count: ServerBackup.maximumFileSize + 1)))
        let server = profile()
        XCTAssertThrowsError(try ServerBackup(servers: [server, server]).encoded())
        var bad = server
        bad.port = 0
        XCTAssertThrowsError(try ServerBackup(servers: [bad]).encoded())
    }

    func testDefaultMergeKeepsLocalAndNeverDeletesUnrelatedServers() throws {
        let local = profile(name: "Local")
        let unrelated = profile(name: "Unrelated")
        let replacement = profile(id: local.id, name: "File")
        let added = profile(name: "Added")
        let plan = try ServerBackup(servers: [replacement, added]).importPlan(current: [local, unrelated], policy: .keepLocal)
        XCTAssertEqual(plan.servers.map(\.name), ["Local", "Unrelated", "Added"])
        XCTAssertEqual(plan.addedIDs, [added.id])
        XCTAssertTrue(plan.updatedIDs.isEmpty)
        XCTAssertEqual(plan.skipped, 1)
    }

    func testUpdatingMetadataKeepsLocalKeyBindingAndCredentialIdentity() throws {
        var local = profile(name: "Local")
        local.authMethod = .privateKey
        local.keyID = UUID()
        var changed = local
        changed.name = "File"
        changed.keyID = UUID()
        let plan = try ServerBackup(servers: [changed]).importPlan(current: [local], policy: .useFile)
        XCTAssertEqual(plan.servers[0].name, "File")
        XCTAssertEqual(plan.servers[0].keyID, local.keyID)
        XCTAssertEqual(plan.updatedIDs, [local.id])
        XCTAssertTrue(plan.credentialResetIDs.isEmpty)
    }

    func testConnectionIdentityChangeRequiresFreshCredentials() throws {
        let local = profile()
        var changed = local
        changed.host = "new.example"
        let plan = try ServerBackup(servers: [changed]).importPlan(current: [local], policy: .useFile)
        XCTAssertEqual(plan.credentialResetIDs, [local.id])
    }

    func testRepeatedImportHasNoNewChanges() throws {
        let backup = ServerBackup(servers: [profile()])
        let first = try backup.importPlan(current: [], policy: .keepLocal)
        XCTAssertEqual(first.addedIDs.count, 1)
        let second = try backup.importPlan(current: first.servers, policy: .useFile)
        XCTAssertEqual(second.changedCount, 0)
        XCTAssertEqual(second.skipped, 1)
    }

    func testCoordinatedFileReadRoundTripAndInvalidFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("backup.json")
        let server = profile()
        try ServerBackup(servers: [server]).encoded().write(to: url)
        XCTAssertEqual(try ServerBackupFiles.read(url).servers, [server])
        try Data("invalid".utf8).write(to: url)
        XCTAssertThrowsError(try ServerBackupFiles.read(url))
    }

    @MainActor
    func testStoreImportIsIdempotentAndReportsOneBatchChange() throws {
        let f = try BackupStoreFixture()
        var changes = 0
        f.store.onLocalChange = { changes += 1 }
        let backup = ServerBackup(servers: [profile(), profile()])
        try f.store.importBackup(backup, policy: .keepLocal)
        try f.store.importBackup(backup, policy: .keepLocal)
        XCTAssertEqual(f.store.servers.count, 2)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(AppFiles.load([ServerProfile].self, from: f.serversURL)?.count, 2)
    }

    @MainActor
    func testStoreKeepsPasswordForMetadataUpdateButClearsForChangedHost() throws {
        let f = try BackupStoreFixture()
        let server = profile()
        defer { KeychainStore.deleteAll(for: server.id) }
        try f.store.save(server, secret: "temporary-test-only")
        var metadata = server
        metadata.name = "Renamed"
        try f.store.importBackup(ServerBackup(servers: [metadata]), policy: .useFile)
        XCTAssertEqual(try KeychainStore.load(for: server.id, kind: .password), "temporary-test-only")
        metadata.host = "new.example"
        try f.store.importBackup(ServerBackup(servers: [metadata]), policy: .useFile)
        XCTAssertNil(try KeychainStore.load(for: server.id, kind: .password))
        XCTAssertEqual(f.store.servers.first?.host, "new.example")
    }

    @MainActor
    func testNewImportDoesNotReuseOrphanedCredentials() throws {
        let f = try BackupStoreFixture()
        let server = profile()
        defer { KeychainStore.deleteAll(for: server.id) }
        try KeychainStore.save("orphaned-test-only", for: server.id, kind: .password)
        try f.store.importBackup(ServerBackup(servers: [server]), policy: .keepLocal)
        XCTAssertNil(try KeychainStore.load(for: server.id, kind: .password))
    }

    @MainActor
    func testRestoreRevivesOnlyExplicitlyImportedTombstone() throws {
        let f = try BackupStoreFixture()
        let first = profile(), other = profile()
        try f.store.save(first, secret: nil)
        try f.store.save(other, secret: nil)
        f.store.delete(first)
        f.store.delete(other)
        try f.store.importBackup(ServerBackup(servers: [first]), policy: .keepLocal)
        XCTAssertNil(f.store.document.tombstones[first.id])
        XCTAssertNotNil(f.store.document.tombstones[other.id])
        XCTAssertEqual(f.store.servers.map(\.id), [first.id])
    }

    @MainActor
    func testPersistenceFailureDoesNotPublishImportedList() throws {
        let f = try BackupStoreFixture()
        let server = profile()
        try f.store.save(server, secret: nil)
        let broken = ServerStore(serversURL: f.serversURL, tombstonesURL: f.directory)
        var changed = server
        changed.name = "File"
        XCTAssertThrowsError(try broken.importBackup(ServerBackup(servers: [changed]), policy: .useFile))
        XCTAssertEqual(broken.servers.map(\.name), [server.name])
        XCTAssertEqual(AppFiles.load([ServerProfile].self, from: f.serversURL)?.map(\.name), [server.name])
    }
}

private final class BackupStoreFixture {
    let directory: URL
    let serversURL: URL
    let store: ServerStore
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        serversURL = directory.appendingPathComponent("servers.json")
        store = ServerStore(serversURL: serversURL, tombstonesURL: directory.appendingPathComponent("tombstones.json"))
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
