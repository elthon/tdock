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
            if phase == .active { CloudSync.shared.refresh() }
            lock.scenePhaseChanged(phase)
            background.scenePhaseChanged(phase)
        }
    }
}

/// 根视图：服务器列表；主机指纹确认框与锁屏/隐私遮罩由独立的呈现器负责（可盖住 sheet）。
struct RootView: View {
    @EnvironmentObject private var manager: SessionManager
    @EnvironmentObject private var lock: AppLock
    @State private var hostKeyPresenter = HostKeyPromptPresenter()
    @State private var overlay = SecurityOverlayController()

    var body: some View {
        ServerListView()
            .onAppear { overlay.start(lock: lock) }
            .onReceive(manager.$hostKeyPrompt) { prompt in
                hostKeyPresenter.show(prompt) { trust in
                    manager.answerHostKeyPrompt(trust: trust)
                }
            }
    }
}
