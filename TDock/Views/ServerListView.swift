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
    @State private var selectedHost: UUID?
    @State private var columns: NavigationSplitViewVisibility = .all
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var sheet: Sheet?
    @State private var pendingDelete: ServerProfile?

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selectedHost) {
                ForEach(store.servers) { server in
                    NavigationLink(value: server.id) {
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
            .navigationBarTitleDisplayMode(.inline)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
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
        } detail: {
            NavigationStack(path: $path) {
                Group {
                    if let selectedHost {
                        HostDetailView(hostID: selectedHost, path: $path)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "terminal").font(.system(size: 44, weight: .light))
                            Text("选择一台服务器").font(.title2.weight(.semibold))
                            Text("从左侧选择服务器，打开终端或管理文件。")
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle("tdock")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .host(let id):
                        HostDetailView(hostID: id, path: $path)
                    case .workspace(let hostID, let terminalID):
                        TerminalWorkspaceView(hostID: hostID, selection: terminalID,
                                              toggleSidebar: horizontalSizeClass == .regular ? toggleSidebar : nil)
                    case .sftp(let hostID):
                        SFTPBrowserView(hostID: hostID)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selectedHost) { _ in path = NavigationPath() }
        .onChange(of: store.servers.map(\.id)) { ids in
            if let selectedHost, !ids.contains(selectedHost) {
                self.selectedHost = nil
                path = NavigationPath()
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

    private func toggleSidebar() {
        withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
    }
}

private struct ServerRow: View {
    let server: ServerProfile
    let openCount: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName).font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "\(server.username)@\(server.host):\(server.port)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
