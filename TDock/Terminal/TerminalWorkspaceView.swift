import SwiftUI
import TDockCore

/// 终端工作区：顶部标签栏 + 当前标签的终端。
/// 左上角主机名是跨主机切换菜单（长按 + 也可打开）：同时连着多台服务器时可直接切到其他主机的终端，不需要退回列表。
struct TerminalWorkspaceView: View {
    @State private var hostID: UUID
    @State private var selection: UUID?
    var toggleSidebar: (() -> Void)?

    init(hostID: UUID, selection: UUID?, toggleSidebar: (() -> Void)? = nil) {
        _hostID = State(initialValue: hostID)
        _selection = State(initialValue: selection)
        self.toggleSidebar = toggleSidebar
    }

    @EnvironmentObject private var manager: SessionManager
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var barHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 44 : (verticalSizeClass == .compact ? 32 : 40)
    }

    private var tabs: [TerminalSession] { manager.terminals(for: hostID) }
    private var selected: TerminalSession? {
        tabs.first { $0.id == selection } ?? tabs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: barHeight)
                }
                .accessibilityLabel("返回主机详情")
                if let toggleSidebar {
                    Button(action: toggleSidebar) {
                        Image(systemName: "sidebar.left")
                            .frame(width: 36, height: barHeight)
                    }
                    .accessibilityLabel("显示或隐藏服务器列表")
                }
                Menu {
                    switcherMenu
                } label: {
                    HStack(spacing: 3) {
                        Text(manager.profile(hostID)?.displayName ?? "")
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .frame(maxWidth: 120, minHeight: barHeight)
                    .padding(.trailing, 4)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("切换主机与终端")
                TerminalTabStrip(tabs: tabs, selection: selected?.id, height: barHeight,
                                 select: select, close: close)
                    .frame(maxWidth: .infinity)
                // 点按：新建标签；长按：跨主机切换菜单。
                Menu {
                    switcherMenu
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: barHeight)
                } primaryAction: {
                    newTab()
                }
                .accessibilityLabel("新建标签（长按切换主机）")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color(white: 0.1))
            Divider()
            if let selected {
                TerminalPane(session: selected)
                    .id(selected.id)
            } else {
                emptyState
            }
        }
        .background(Color(settings.theme.background))
        .navigationTitle(manager.profile(hostID)?.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .background { hardwareKeyboardShortcuts }
        .onAppear { selected?.lastActiveAt = Date() }
    }

    /// 所有活动终端（按主机分组）+ 在其他服务器新建终端。
    @ViewBuilder
    private var switcherMenu: some View {
        ForEach(manager.activeHostIDs, id: \.self) { id in
            Section(manager.profile(id)?.displayName ?? "") {
                ForEach(manager.terminals(for: id)) { session in
                    Button {
                        switchTo(session)
                    } label: {
                        if session.id == selected?.id {
                            Label(session.title, systemImage: "checkmark")
                        } else {
                            Label(session.title, systemImage: Self.symbol(for: session.phase))
                        }
                    }
                }
            }
        }
        Section {
            Button {
                newTab()
            } label: {
                Label("在 \(manager.profile(hostID)?.displayName ?? "") 新建终端", systemImage: "plus")
            }
            let others = manager.store.servers.filter { $0.id != hostID }
            if !others.isEmpty {
                Menu {
                    ForEach(others) { server in
                        Button(server.displayName) { openTerminal(on: server.id) }
                    }
                } label: {
                    Label("在其他服务器新建终端", systemImage: "server.rack")
                }
            }
        }
    }

    private static func symbol(for phase: TerminalSession.Phase) -> String {
        switch phase {
        case .connected: return "circle.fill"
        case .connecting, .reconnecting: return "circle.dotted"
        case .ended: return "pause.circle"
        }
    }

    private func switchTo(_ session: TerminalSession) {
        hostID = session.hostID
        select(session)
    }

    private func openTerminal(on otherHostID: UUID) {
        switchTo(manager.openTerminal(hostID: otherHostID))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("没有打开的终端").foregroundStyle(.secondary)
            Button("新建终端", action: newTab).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 外接键盘：⌘T 新建，⌘W 关闭，⌘1…9 切换，⌘⇧[ / ⌘⇧] 上一个/下一个，⌘+ / ⌘- 字号。
    private var hardwareKeyboardShortcuts: some View {
        ZStack {
            Button("", action: newTab)
                .keyboardShortcut("t", modifiers: .command)
            Button("") { if let selected { close(selected) } }
                .keyboardShortcut("w", modifiers: .command)
            Button("") { cycle(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("") { cycle(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("") { settings.adjustFontSize(by: 1) }
                .keyboardShortcut("=", modifiers: .command)
            Button("") { settings.adjustFontSize(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
            ForEach(1..<10) { number in
                Button("") {
                    if number <= tabs.count { select(tabs[number - 1]) }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func select(_ session: TerminalSession) {
        selection = session.id
        session.lastActiveAt = Date()
    }

    private func newTab() {
        select(manager.openTerminal(hostID: hostID))
    }

    private func close(_ session: TerminalSession) {
        let remaining = tabs.filter { $0 !== session }
        if session.id == selected?.id, let index = tabs.firstIndex(where: { $0 === session }) {
            selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        }
        manager.close(session)
    }

    private func cycle(_ delta: Int) {
        guard !tabs.isEmpty, let current = selected, let index = tabs.firstIndex(where: { $0 === current }) else { return }
        select(tabs[(index + delta + tabs.count) % tabs.count])
    }
}

/// 横向标签栏。
private struct TerminalTabStrip: View {
    let tabs: [TerminalSession]
    let selection: UUID?
    let height: CGFloat
    let select: (TerminalSession) -> Void
    let close: (TerminalSession) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        TerminalTabChip(session: tab, isSelected: tab.id == selection, height: height,
                                        select: { select(tab) }, close: { close(tab) })
                            .id(tab.id)
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(height: height)
            .onChange(of: selection) { id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
        }
        .background(Color(white: 0.1))
    }
}

private struct TerminalTabChip: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let height: CGFloat
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(session.title)
                        .font(.footnote.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                }
                .padding(.leading, 10)
                .frame(minHeight: height)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("切换到 \(session.title)")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            Button(action: close) {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
                    .frame(width: 32, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭 \(session.title)")
        }
        .foregroundStyle(isSelected ? Color.white : Color.gray)
        .buttonStyle(.plain)
        .background {
            Capsule().fill(isSelected ? Color(white: 0.25) : Color(white: 0.15))
                .frame(height: min(height, dynamicChipHeight))
        }
        .contentShape(Capsule())
    }

    private var statusColor: Color {
        switch session.phase {
        case .connecting: return .yellow
        case .connected: return .green
        case .reconnecting: return .orange
        case .ended(let message): return message == nil ? .gray : .red
        }
    }

    private var dynamicChipHeight: CGFloat { height >= 44 ? 40 : 28 }
}
