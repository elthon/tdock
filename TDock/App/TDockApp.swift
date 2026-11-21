import SwiftUI

@main
struct TDockApp: App {
    @StateObject private var store = ServerStore()

    var body: some Scene {
        WindowGroup {
            ServerListView()
                .environmentObject(store)
        }
    }
}
