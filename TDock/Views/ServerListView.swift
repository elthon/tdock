import SwiftUI
import TDockCore

struct ServerListView: View {
    @EnvironmentObject private var store: ServerStore
    @EnvironmentObject private var manager: SessionManager

    private enum Sheet: Identifiable {
        case new
        case edit(ServerProfile)
        case settings

        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let profile): return profile.id.uuidString
            case .settings: return "settings"
            }
        }
    }

    @State private var path = NavigationPath()
    @State private var sheet: Sheet?
    @State private var pendingDelete: ServerProfile?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(store.servers) { server in
                    NavigationLink(value: Route.host(server.id)) {
                        ServerRow(server: server, openCount: manager.terminals(for: server.id).count)
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { pendingDelete = server }
                        Button("编辑") { sheet = .edit(server) }
                            .tint(.blue)
                    }
                    .contextMenu {
                        Button { sheet = .edit(server) } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        Button(role: .destructive) { pendingDelete = server } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .overlay {
                if store.servers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "server.rack").font(.largeTitle)
                        Text("还没有服务器").font(.headline)
                        Text("点击右上角 + 添加").foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("tdock")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .host(let id):
                    HostDetailView(hostID: id, path: $path)
                case .workspace(let hostID, let terminalID):
                    TerminalWorkspaceView(hostID: hostID, selection: terminalID)
                case .sftp(let hostID):
                    SFTPBrowserView(hostID: hostID)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { sheet = .settings } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { sheet = .new } label: { Image(systemName: "plus") }
                        .accessibilityLabel("添加服务器")
                }
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .new: ServerEditView(profile: nil)
                case .edit(let profile): ServerEditView(profile: profile)
                case .settings: SettingsView()
                }
            }
            .confirmationDialog(
                "删除服务器？",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { server in
                Button("删除 \(server.displayName)", role: .destructive) {
                    manager.closeAll(hostID: server.id)
                    store.delete(server)
                }
            } message: { _ in
                Text("将同时关闭其终端，并从本机 Keychain 中删除其密码/私钥。")
            }
        }
    }
}

private struct ServerRow: View {
    let server: ServerProfile
    let openCount: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName).font(.headline)
                Text(verbatim: "\(server.username)@\(server.host):\(server.port)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if server.transport == .mosh {
                Text("Mosh").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
            if openCount > 0 {
                Label("\(openCount)", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }
}
