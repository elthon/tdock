import SwiftUI
import TDockCore

/// 主机详情页的 “tmux Sessions” 分区：全部 tmux 会话（名称、创建时间、In use），支持新建、切换、重命名、删除。
struct TmuxSessionsSection: View {
    let hostID: UUID
    let open: (String) -> Void

    @EnvironmentObject private var manager: SessionManager
    @StateObject private var model = TmuxSessionsModel()
    @State private var newName = ""
    @State private var creating = false
    @State private var renaming: TmuxSession?
    @State private var renameText = ""
    @State private var pendingKill: TmuxSession?

    var body: some View {
        Section {
            content
        } header: {
            HStack {
                Text("tmux Sessions")
                Spacer()
                if model.isLoading { ProgressView().controlSize(.mini) }
            }
        }
        .task { await model.load(manager.connection(for: hostID)) }
        .onChange(of: manager.terminals.count) { _ in
            Task { await model.load(manager.connection(for: hostID)) }
        }
        .alert("新建 tmux 会话", isPresented: $creating) {
            TextField("会话名", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("创建并打开") { create() }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名会话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { session in
            TextField("新名称", text: $renameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("重命名") { rename(session) }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "结束 tmux 会话？",
            isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
            titleVisibility: .visible,
            presenting: pendingKill
        ) { session in
            Button("结束 \(session.name)", role: .destructive) { kill(session) }
        } message: { _ in
            Text("会话中运行的程序将被终止。")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .notInstalled:
            VStack(alignment: .leading, spacing: 8) {
                Label("服务器未安装 tmux", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                Text("检测命令 command -v tmux 未找到 tmux。请先在服务器上安装：")
                    .font(.footnote)
                Text(TmuxError.installHint)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button("重新检测") { reload() }
            }
            .padding(.vertical, 4)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            Button("重试") { reload() }
        case .idle, .loaded:
            if model.sessions.isEmpty && model.state != .idle {
                Text("没有 tmux 会话").foregroundStyle(.secondary)
            }
            ForEach(model.sessions) { session in
                TmuxSessionRow(session: session)
                    .contentShape(Rectangle())
                    .onTapGesture { open(session.name) }
                    .accessibilityAddTraits(.isButton)
                    .swipeActions {
                        Button("删除", role: .destructive) { pendingKill = session }
                        Button("重命名") {
                            renameText = session.name
                            renaming = session
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button { open(session.name) } label: { Label("切换到此会话", systemImage: "arrow.right.circle") }
                        Button { renameText = session.name; renaming = session } label: { Label("重命名", systemImage: "pencil") }
                        Button(role: .destructive) { pendingKill = session } label: { Label("删除", systemImage: "trash") }
                    }
            }
            Button {
                newName = model.suggestedName
                creating = true
            } label: {
                Label("新建 tmux 会话", systemImage: "plus")
            }
            if let error = model.actionError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func reload() {
        Task { await model.load(manager.connection(for: hostID)) }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        do {
            try TmuxCommands.validate(name)
            model.actionError = nil
            open(name) // new-session -A：不存在则创建
        } catch {
            model.actionError = error.localizedDescription
        }
    }

    private func rename(_ session: TmuxSession) {
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        Task {
            if await model.rename(session.name, to: newName) {
                manager.tmuxSessionRenamed(hostID: hostID, from: session.name, to: newName)
            }
        }
    }

    private func kill(_ session: TmuxSession) {
        Task { await model.kill(session.name) }
    }
}

private struct TmuxSessionRow: View {
    let session: TmuxSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.split.2x2").foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name).font(.headline)
                HStack(spacing: 6) {
                    Text(session.createdAt, format: .dateTime.month().day().hour().minute())
                    Text("· \(session.windows) 个窗口")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if session.isInUse {
                Text("In use")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.green.opacity(0.15), in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}

@MainActor
final class TmuxSessionsModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loaded
        case notInstalled
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var sessions: [TmuxSession] = []
    @Published private(set) var isLoading = false
    @Published var actionError: String?

    private var manager: TmuxManager?
    private var installedChecked = false

    var suggestedName: String {
        var index = sessions.count + 1
        while sessions.contains(where: { $0.name == "session-\(index)" }) { index += 1 }
        return "session-\(index)"
    }

    func load(_ connection: HostConnection) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try await connection.client()
            let tmux = TmuxManager(client: client)
            manager = tmux
            if !installedChecked || state == .notInstalled {
                try await tmux.ensureInstalled()
                installedChecked = true
            }
            sessions = try await tmux.list()
            state = .loaded
        } catch TmuxError.notInstalled {
            state = .notInstalled
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func rename(_ name: String, to newName: String) async -> Bool {
        do {
            try await manager?.rename(name, to: newName)
            actionError = nil
            await refresh()
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    func kill(_ name: String) async {
        do {
            try await manager?.kill(name)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
        await refresh()
    }

    private func refresh() async {
        guard let manager else { return }
        sessions = (try? await manager.list()) ?? sessions
    }
}
