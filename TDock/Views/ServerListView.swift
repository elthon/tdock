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
    @State private var query = ""
    /// 切换所选主机时会重置详情栈；一键直达终端等操作在重置之后再压入目标页面。
    @State private var pendingRoute: Route?

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selectedHost) {
                ForEach(ServerListOrganizer.sections(store.servers, query: query)) { section in
                    Section {
                        ForEach(section.servers) { server in
                            row(server)
                        }
                    } header: {
                        if let title = section.title {
                            Label(title, systemImage: section.kind == .pinned ? "pin.fill" : "folder")
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索名称、主机、用户、分组")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .overlay {
                if !store.servers.isEmpty && !query.isEmpty && ServerListOrganizer.sections(store.servers, query: query).isEmpty {
                    Text("没有匹配“\(query)”的服务器").foregroundStyle(.secondary)
                } else if store.servers.isEmpty {
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
        .onChange(of: selectedHost) { _ in
            path = NavigationPath()
            if let route = pendingRoute {
                path.append(route)
                pendingRoute = nil
            }
        }
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

    private func row(_ server: ServerProfile) -> some View {
        let open = manager.terminals(for: server.id)
        return NavigationLink(value: server.id) {
            ServerRow(server: server, openCount: open.count) {
                quickOpen(server)
            }
        }
        .swipeActions(edge: .leading) {
            Button { openNewTerminal(server) } label: { Label("新建终端", systemImage: "plus.rectangle") }
                .tint(.green)
            if !open.isEmpty {
                Button { resumeTerminal(server) } label: { Label("恢复终端", systemImage: "terminal") }
                    .tint(.indigo)
            }
        }
        .swipeActions {
            Button("删除", role: .destructive) { pendingDelete = server }
            Button("编辑") { sheet = .edit(server) }
                .tint(.blue)
            Button(server.pinned ? "取消置顶" : "置顶") { togglePin(server) }
                .tint(.orange)
        }
        .contextMenu {
            Button { openNewTerminal(server) } label: {
                Label("新建终端", systemImage: "plus.rectangle")
            }
            if !open.isEmpty {
                Button { resumeTerminal(server) } label: {
                    Label("恢复最近终端", systemImage: "terminal")
                }
            }
            Button { show(server, route: .sftp(hostID: server.id)) } label: {
                Label("文件（SFTP）", systemImage: "folder")
            }
            Divider()
            Button { togglePin(server) } label: {
                Label(server.pinned ? "取消置顶" : "置顶", systemImage: server.pinned ? "pin.slash" : "pin")
            }
            Button { sheet = .edit(server) } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive) { pendingDelete = server } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 选中主机并在详情栈中打开指定页面（终端 / SFTP）。
    private func show(_ server: ServerProfile, route: Route) {
        if selectedHost == server.id {
            path = NavigationPath()
            path.append(route)
        } else {
            pendingRoute = route
            selectedHost = server.id
        }
    }

    /// 一键直达：有打开的终端则恢复最近使用的那个，否则新建。
    private func quickOpen(_ server: ServerProfile) {
        if manager.mostRecentTerminal(hostID: server.id) != nil {
            resumeTerminal(server)
        } else {
            openNewTerminal(server)
        }
    }

    private func openNewTerminal(_ server: ServerProfile) {
        let session = manager.openTerminal(hostID: server.id)
        show(server, route: .workspace(hostID: server.id, terminalID: session.id))
    }

    private func resumeTerminal(_ server: ServerProfile) {
        let session = manager.mostRecentTerminal(hostID: server.id)
        show(server, route: .workspace(hostID: server.id, terminalID: session?.id))
    }

    private func togglePin(_ server: ServerProfile) {
        var updated = server
        updated.pinned.toggle()
        try? store.save(updated, secret: nil)
    }
}

private struct ServerRow: View {
    let server: ServerProfile
    let openCount: Int
    let openTerminal: () -> Void

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
                Text("\(openCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.green)
            }
            // 一键直达终端（borderless：点按钮不会触发整行的导航）。
            Button(action: openTerminal) {
                Image(systemName: openCount > 0 ? "terminal.fill" : "terminal")
                    .font(.title3)
                    .foregroundStyle(openCount > 0 ? Color.green : Color.accentColor)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(openCount > 0 ? "恢复最近终端" : "新建终端")
        }
    }
}
