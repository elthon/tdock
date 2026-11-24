import Combine
import Foundation
import TDockCore

protocol CloudKeyValueStoring: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: CloudKeyValueStoring {}

/// Only server configuration is shared; passwords and private keys remain in Keychain.
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()
    static let documentKey = "servers.v1"

    enum Status: Equatable {
        case checking, notConfigured, accountUnavailable, disabled, waiting, queued
        case failed(Failure)
    }

    enum Failure: Equatable {
        case requestRejected, quotaExceeded, invalidRemoteData, encodingFailed
    }

    @Published private(set) var status: Status = .checking
    @Published private(set) var isConfigured = false
    @Published private(set) var accountAvailable = false
    @Published private(set) var lastReceivedAt: Date?
    @Published private(set) var lastSubmittedAt: Date?

    var canUseICloud: Bool { isConfigured && accountAvailable }

    private let kvs: CloudKeyValueStoring
    private let configuration: () -> Bool
    private let accountToken: () -> NSObject?
    private let now: () -> Date
    private let notifications: NotificationCenter
    private weak var store: ServerStore?
    private weak var settings: AppSettings?
    private var identity: NSObject?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    init(kvs: CloudKeyValueStoring = NSUbiquitousKeyValueStore.default,
         configuration: @escaping () -> Bool = CloudSync.buildSupportsICloud,
         accountToken: @escaping () -> NSObject? = { FileManager.default.ubiquityIdentityToken as? NSObject },
         notifications: NotificationCenter = .default,
         now: @escaping () -> Date = Date.init) {
        self.kvs = kvs
        self.configuration = configuration
        self.accountToken = accountToken
        self.notifications = notifications
        self.now = now
    }

    deinit {
        for observer in observers { notifications.removeObserver(observer) }
    }

    /// Generated from the actual signing entitlements for this build, including
    /// local Personal Team overrides. Missing metadata fails closed.
    nonisolated static func buildSupportsICloud() -> Bool {
        guard let url = Bundle.main.url(forResource: "SyncCapabilities", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = plist as? [String: Any] else { return false }
        return values["supportsICloudKeyValueStore"] as? Bool == true
    }

    func start(store: ServerStore, settings: AppSettings) {
        guard self.store == nil else { return }
        self.store = store
        self.settings = settings
        store.onLocalChange = { [weak self] in self?.push() }

        observers.append(notifications.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs, queue: .main
        ) { [weak self] notification in
            let reason = (notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? NSNumber)?.intValue
            let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            Task { @MainActor in self?.receiveChange(reason: reason, keys: keys) }
        })
        observers.append(notifications.addObserver(
            forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        settings.$iCloudSyncEnabled.removeDuplicates().dropFirst().sink { [weak self] _ in
            // @Published emits before the value is stored.
            Task { @MainActor in self?.refresh() }
        }.store(in: &cancellables)
        refresh()
    }

    /// synchronize() only asks the system to synchronize its local cache. It
    /// cannot prove that another device has received our data.
    func refresh() {
        guard checkAvailability() else { return }
        guard kvs.synchronize() else {
            status = .failed(.requestRejected)
            return
        }
        reconcile(receivedUpdate: false)
    }

    private func checkAvailability() -> Bool {
        isConfigured = configuration()
        let token = isConfigured ? accountToken() : nil
        if !(identity?.isEqual(token) ?? (token == nil)) {
            lastReceivedAt = nil
            lastSubmittedAt = nil
            identity = token
        }
        accountAvailable = token != nil
        guard isConfigured else { status = .notConfigured; return false }
        guard accountAvailable else { status = .accountUnavailable; return false }
        guard settings?.iCloudSyncEnabled == true else { status = .disabled; return false }
        return true
    }

    private func push() {
        guard checkAvailability() else { return }
        // Normal writes are synchronized automatically; avoid a request on every edit.
        reconcile(receivedUpdate: false)
    }

    func receiveChange(reason: Int?, keys: [String]?) {
        if reason == NSUbiquitousKeyValueStoreAccountChange {
            lastReceivedAt = nil
            lastSubmittedAt = nil
            refresh()
            return
        }
        guard checkAvailability() else { return }
        if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
            status = .failed(.quotaExceeded)
            return
        }
        guard reason == NSUbiquitousKeyValueStoreServerChange || reason == NSUbiquitousKeyValueStoreInitialSyncChange,
              keys == nil || keys!.contains(Self.documentKey) else { return }
        reconcile(receivedUpdate: true)
    }

    private func reconcile(receivedUpdate: Bool) {
        guard let store else { return }
        let data = kvs.data(forKey: Self.documentKey)
        let remote: SyncDocument?
        do {
            remote = try data.map(SyncDocument.decode)
        } catch {
            // Preserve both copies rather than overwriting an unreadable remote document.
            status = .failed(.invalidRemoteData)
            return
        }
        let merged = remote.map { ServerSync.merge(local: store.document, remote: $0) } ?? store.document
        let encoded: Data
        do { encoded = try merged.encoded() }
        catch { status = .failed(.encodingFailed); return }
        guard encoded.count <= 1_048_576 else { status = .failed(.quotaExceeded); return }
        store.apply(merged)
        if receivedUpdate, remote != nil { lastReceivedAt = now() }
        if remote != merged {
            kvs.set(encoded, forKey: Self.documentKey)
            lastSubmittedAt = now()
            status = .queued
        } else {
            status = lastSubmittedAt == nil ? .waiting : .queued
        }
    }
}
