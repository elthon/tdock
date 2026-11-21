import Combine
import Foundation
import TDockCore

/// 通过 iCloud 键值存储同步服务器配置。
///
/// 只同步 `SyncDocument`（主机、端口、用户名、认证方式、连接方式、端口转发规则、删除记录），
/// **不含任何密码/私钥**：凭据始终只在各设备本机的 Keychain（ThisDeviceOnly）中。
/// 需要 iCloud Key-Value Storage 权限（见 TDock.entitlements）；未登录 iCloud 时自动成为本地模式。
@MainActor
final class CloudSync {
    static let shared = CloudSync()

    private static let key = "servers.v1"
    private let kvs = NSUbiquitousKeyValueStore.default
    private weak var store: ServerStore?
    private weak var settings: AppSettings?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    func start(store: ServerStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        store.onLocalChange = { [weak self] in self?.push() }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pull() }
        })
        // 开关打开时立即做一次双向合并。
        settings.$iCloudSyncEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard enabled else { return }
                Task { @MainActor in
                    self?.kvs.synchronize()
                    self?.pull()
                    self?.push()
                }
            }
            .store(in: &cancellables)
    }

    private var enabled: Bool { settings?.iCloudSyncEnabled == true }

    private var remoteDocument: SyncDocument? {
        kvs.data(forKey: Self.key).flatMap { try? SyncDocument.decode($0) }
    }

    /// 合并远端变更到本地。
    private func pull() {
        guard enabled, let store, let remote = remoteDocument else { return }
        store.apply(ServerSync.merge(local: store.document, remote: remote))
    }

    /// 把本地（与远端合并后的）文档写回 iCloud。
    private func push() {
        guard enabled, let store else { return }
        let merged = remoteDocument.map { ServerSync.merge(local: store.document, remote: $0) } ?? store.document
        store.apply(merged)
        guard let data = try? merged.encoded(), data != kvs.data(forKey: Self.key) else { return }
        kvs.set(data, forKey: Self.key)
        kvs.synchronize()
    }
}
