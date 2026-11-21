import SwiftUI

@main
struct TDockApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var store: ServerStore
    @StateObject private var manager: SessionManager
    @StateObject private var keys = KeyLibrary()
    @StateObject private var lock: AppLock
    @StateObject private var background: BackgroundKeeper
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let settings = AppSettings()
        let store = ServerStore()
        let manager = SessionManager(store: store, settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: store)
        _manager = StateObject(wrappedValue: manager)
        _lock = StateObject(wrappedValue: AppLock(settings: settings))
        _background = StateObject(wrappedValue: BackgroundKeeper(manager: manager))
        CloudSync.shared.start(store: store, settings: settings)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(manager)
                .environmentObject(keys)
                .environmentObject(lock)
        }
        .onChange(of: scenePhase) { phase in
            lock.scenePhaseChanged(phase)
            background.scenePhaseChanged(phase)
        }
    }
}

/// 根视图：服务器列表 + 全局主机密钥确认框 + Face ID 锁屏遮罩。
struct RootView: View {
    @EnvironmentObject private var manager: SessionManager
    @EnvironmentObject private var lock: AppLock

    var body: some View {
        ServerListView()
            .alert(
                "首次连接此主机",
                isPresented: Binding(
                    get: { manager.hostKeyPrompt != nil },
                    set: { if !$0, manager.hostKeyPrompt != nil { manager.answerHostKeyPrompt(trust: false) } }
                ),
                presenting: manager.hostKeyPrompt
            ) { _ in
                Button("信任并连接") { manager.answerHostKeyPrompt(trust: true) }
                Button("取消", role: .cancel) { manager.answerHostKeyPrompt(trust: false) }
            } message: { prompt in
                Text("""
                \(prompt.host):\(String(prompt.port)) 的主机密钥尚未记录。
                请核对指纹后再确认：

                \(prompt.key.keyType)
                \(prompt.key.fingerprint)
                """)
            }
            .overlay {
                if lock.isLocked {
                    LockScreen()
                }
            }
    }
}
