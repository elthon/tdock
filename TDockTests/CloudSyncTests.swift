import Foundation
import TDockCore
import XCTest
@testable import TDock

final class CloudSyncTests: XCTestCase {
    @MainActor
    func testMissingCapabilityDisablesCloudAccessWithoutChangingPreference() throws {
        let f = try Fixture(configured: false)
        XCTAssertEqual(f.sync.status, .notConfigured)
        XCTAssertFalse(f.sync.canUseICloud)
        XCTAssertTrue(f.settings.iCloudSyncEnabled)
        XCTAssertEqual(f.cloud.requests, 0)
        XCTAssertEqual(f.cloud.writes, 0)
    }

    @MainActor
    func testUnavailableAccountDoesNotTouchCloudStore() throws {
        let f = try Fixture(account: nil)
        XCTAssertEqual(f.sync.status, .accountUnavailable)
        XCTAssertFalse(f.sync.canUseICloud)
        XCTAssertEqual(f.cloud.requests, 0)
        XCTAssertEqual(f.cloud.reads, 0)
    }

    @MainActor
    func testDisabledPreferenceDoesNotTouchCloudStore() throws {
        let f = try Fixture(enabled: false)
        XCTAssertEqual(f.sync.status, .disabled)
        XCTAssertEqual(f.cloud.requests, 0)
    }

    @MainActor
    func testRejectedRequestDoesNotMergeOrClaimSuccess() throws {
        let f = try Fixture(requestSucceeds: false)
        XCTAssertEqual(f.sync.status, .failed(.requestRejected))
        XCTAssertEqual(f.cloud.reads, 0)
        XCTAssertEqual(f.cloud.writes, 0)
        XCTAssertNil(f.sync.lastSubmittedAt)
        XCTAssertNil(f.sync.lastReceivedAt)
    }

    @MainActor
    func testAcceptedRequestDoesNotClaimCloudDelivery() throws {
        let f = try Fixture()
        XCTAssertEqual(f.sync.status, .waiting)
        XCTAssertNil(f.sync.lastReceivedAt)
        XCTAssertNil(f.sync.lastSubmittedAt)
    }

    @MainActor
    func testLocalWritesAreQueuedWithoutClaimingRemoteReceipt() throws {
        let f = try Fixture()
        let server = ServerProfile(name: "Local test", host: "127.0.0.1", username: "test")
        try f.store.save(server, secret: nil)
        XCTAssertEqual(f.sync.status, .queued)
        XCTAssertEqual(f.sync.lastSubmittedAt, f.date)
        XCTAssertNil(f.sync.lastReceivedAt)
        XCTAssertEqual(f.cloud.requests, 1)
        let data = try XCTUnwrap(f.cloud.values[CloudSync.documentKey])
        XCTAssertEqual(try SyncDocument.decode(data).servers.map(\.id), [server.id])
    }

    @MainActor
    func testOnlyValidIncomingDocumentRecordsReceipt() throws {
        let f = try Fixture()
        let server = ServerProfile(name: "Remote test", host: "127.0.0.1", username: "test")
        f.cloud.values[CloudSync.documentKey] = try SyncDocument(servers: [server]).encoded()
        f.sync.receiveChange(reason: NSUbiquitousKeyValueStoreServerChange, keys: [CloudSync.documentKey])
        XCTAssertEqual(f.store.servers.map(\.id), [server.id])
        XCTAssertEqual(f.sync.lastReceivedAt, f.date)
    }

    @MainActor
    func testUnrelatedKeysAndQuotaErrorsDoNotRecordReceipt() throws {
        let f = try Fixture()
        f.sync.receiveChange(reason: NSUbiquitousKeyValueStoreServerChange, keys: ["unrelated"])
        XCTAssertNil(f.sync.lastReceivedAt)
        f.sync.receiveChange(reason: NSUbiquitousKeyValueStoreQuotaViolationChange, keys: nil)
        XCTAssertEqual(f.sync.status, .failed(.quotaExceeded))
        XCTAssertNil(f.sync.lastReceivedAt)
    }

    @MainActor
    func testUnreadableRemoteDataPreservesBothCopies() throws {
        let f = try Fixture()
        let server = ServerProfile(name: "Local test", host: "127.0.0.1", username: "test")
        try f.store.save(server, secret: nil)
        let invalid = Data("unreadable document".utf8)
        f.cloud.values[CloudSync.documentKey] = invalid
        let previousWrites = f.cloud.writes
        f.sync.receiveChange(reason: NSUbiquitousKeyValueStoreInitialSyncChange, keys: [CloudSync.documentKey])
        XCTAssertEqual(f.sync.status, .failed(.invalidRemoteData))
        XCTAssertEqual(f.store.servers.map(\.id), [server.id])
        XCTAssertEqual(f.cloud.values[CloudSync.documentKey], invalid)
        XCTAssertEqual(f.cloud.writes, previousWrites)
        XCTAssertNil(f.sync.lastReceivedAt)
    }

    @MainActor
    func testIncomingChangeRepublishesMergeWithoutLosingLocalServer() throws {
        let f = try Fixture()
        let local = ServerProfile(name: "Local", host: "127.0.0.1", username: "test")
        let remote = ServerProfile(name: "Remote", host: "127.0.0.1", username: "test")
        try f.store.save(local, secret: nil)
        f.cloud.values[CloudSync.documentKey] = try SyncDocument(servers: [remote]).encoded()
        f.sync.receiveChange(reason: NSUbiquitousKeyValueStoreServerChange, keys: [CloudSync.documentKey])
        let merged = try SyncDocument.decode(XCTUnwrap(f.cloud.values[CloudSync.documentKey]))
        XCTAssertEqual(Set(merged.servers.map(\.id)), Set([local.id, remote.id]))
        XCTAssertEqual(f.sync.lastReceivedAt, f.date)
        XCTAssertEqual(f.sync.status, .queued)
    }

    @MainActor
    func testAccountSignOutClearsOldAccountTimestamps() throws {
        let f = try Fixture()
        f.sync.receiveChange(reason: NSUbiquitousKeyValueStoreServerChange, keys: nil)
        XCTAssertNotNil(f.sync.lastReceivedAt)
        f.account = nil
        f.sync.refresh()
        XCTAssertEqual(f.sync.status, .accountUnavailable)
        XCTAssertNil(f.sync.lastReceivedAt)
        XCTAssertNil(f.sync.lastSubmittedAt)
    }

    @MainActor
    func testDisablingSyncIgnoresIncomingUpdates() throws {
        let f = try Fixture()
        f.settings.iCloudSyncEnabled = false
        f.sync.receiveChange(reason: NSUbiquitousKeyValueStoreServerChange, keys: nil)
        XCTAssertEqual(f.sync.status, .disabled)
        XCTAssertNil(f.sync.lastReceivedAt)
    }
}

private final class FakeCloudStore: NSObject, CloudKeyValueStoring {
    var values: [String: Data] = [:]
    var succeeds = true
    var requests = 0
    var writes = 0
    var reads = 0
    func data(forKey key: String) -> Data? { reads += 1; return values[key] }
    func set(_ value: Any?, forKey key: String) { writes += 1; values[key] = value as? Data }
    func synchronize() -> Bool { requests += 1; return succeeds }
}

@MainActor
private final class Fixture {
    let date = Date(timeIntervalSince1970: 1_000)
    let cloud = FakeCloudStore()
    let store: ServerStore
    let settings: AppSettings
    var sync: CloudSync!
    var account: NSObject?
    private let directory: URL
    private let suite: String

    init(configured: Bool = true, account: NSObject? = NSString(string: "test-account"),
         enabled: Bool = true, requestSucceeds: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "CloudSyncTests.\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.iCloudSyncEnabled = enabled
        store = ServerStore(serversURL: directory.appendingPathComponent("servers.json"),
                            tombstonesURL: directory.appendingPathComponent("tombstones.json"))
        self.account = account
        cloud.succeeds = requestSucceeds
        cloud.values[CloudSync.documentKey] = try SyncDocument().encoded()
        sync = CloudSync(kvs: cloud, configuration: { configured },
                         accountToken: { [weak self] in self?.account },
                         notifications: NotificationCenter(), now: { [date] in date })
        sync.start(store: store, settings: settings)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}
