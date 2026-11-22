import SwiftUI
import TDockCore

/// 应用内导航目标。
enum Route: Hashable {
    case host(UUID)
    case workspace(hostID: UUID, terminalID: UUID?)
    case sftp(hostID: UUID)
}

/// 主机详情页：Terminal Activity（打开中的终端）、tmux Sessions、端口转发、SFTP 入口。
struct HostDetailView: View {
    let hostID: UUID

    @EnvironmentObject private var manager: SessionManager
    @EnvironmentObject private var store: ServerStore
    @Binding var path: NavigationPath

    private var profile: ServerProfile? { store.servers.first { $0.id == hostID } }

    var body: some View {
        List {
            if let profile {
                Section {
                    LabeledContent("地址", value: "\(profile.username)@\(profile.host):\(String(profile.port))")
                    LabeledContent("连接方式", value: profile.transport == .mosh ? "Mosh" : "SSH")
                    Button {
                        openTerminal(.shell)
                    } label: {
                        Label("新建终端", systemImage: "terminal")
                    }
                    NavigationLink(value: Route.sftp(hostID: hostID)) {
                        Label("文件（SFTP）", systemImage: "folder")
                    }
                }

                TerminalActivitySection(hostID: hostID, open: openExisting)
                TmuxSessionsSection(hostID: hostID, open: { openTerminal(.tmux($0)) })
                PortForwardsSection(hostID: hostID)
            }
        }
        .navigationTitle(profile?.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func openTerminal(_ kind: TerminalSession.Kind) {
        let session = manager.openTerminal(hostID: hostID, kind: kind)
        path.append(Route.workspace(hostID: hostID, terminalID: session.id))
    }

    private func openExisting(_ session: TerminalSession) {
        path.append(Route.workspace(hostID: hostID, terminalID: session.id))
    }
}

/// “Terminal Activity”：当前打开中的终端卡片。
private struct TerminalActivitySection: View {
    let hostID: UUID
    let open: (TerminalSession) -> Void
    @EnvironmentObject private var manager: SessionManager

    var body: some View {
        let sessions = manager.terminals(for: hostID)
        Section {
            if sessions.isEmpty {
                Text("没有打开的终端").foregroundStyle(.secondary)
            }
            ForEach(sessions) { session in
                TerminalActivityCard(session: session)
                    .contentShape(Rectangle())
                    .onTapGesture { open(session) }
                    .accessibilityAddTraits(.isButton)
                    .swipeActions {
                        Button("关闭", role: .destructive) { manager.close(session) }
                    }
            }
        } header: {
            Text("Terminal Activity")
        }
    }
}

private struct TerminalActivityCard: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.kind.tmuxName == nil ? "terminal" : "square.split.2x2")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.headline)
                Text(session.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(session.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            phaseBadge
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var phaseBadge: some View {
        switch session.phase {
        case .connecting, .reconnecting: ProgressView()
        case .connected: Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.green)
        case .ended: Image(systemName: "pause.circle").foregroundStyle(.secondary)
        }
    }
}
