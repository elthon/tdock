import SwiftUI
import TDockCore

struct ServerListView: View {
    @EnvironmentObject private var store: ServerStore

    private enum EditTarget: Identifiable {
        case new
        case existing(ServerProfile)

        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let profile): return profile.id.uuidString
            }
        }
    }

    @State private var editTarget: EditTarget?
    @State private var pendingDelete: ServerProfile?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.servers) { server in
                    NavigationLink(value: server) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.displayName).font(.headline)
                            Text(verbatim: "\(server.username)@\(server.host):\(server.port)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { pendingDelete = server }
                        Button("编辑") { editTarget = .existing(server) }
                            .tint(.blue)
                    }
                    .contextMenu {
                        Button { editTarget = .existing(server) } label: {
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
            .navigationDestination(for: ServerProfile.self) { server in
                TerminalScreen(profile: server)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { editTarget = .new } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加服务器")
                }
            }
            .sheet(item: $editTarget) { target in
                switch target {
                case .new: ServerEditView(profile: nil)
                case .existing(let profile): ServerEditView(profile: profile)
                }
            }
            .confirmationDialog(
                "删除服务器？",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { server in
                Button("删除 \(server.displayName)", role: .destructive) { store.delete(server) }
            } message: { _ in
                Text("将同时从 Keychain 中删除其密码/私钥。")
            }
        }
    }
}
