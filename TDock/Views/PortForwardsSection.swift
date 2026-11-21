import SwiftUI
import TDockCore

/// 主机详情页中的“端口转发”分区：规则列表 + 启停开关。
struct PortForwardsSection: View {
    let hostID: UUID
    @EnvironmentObject private var store: ServerStore
    @EnvironmentObject private var manager: SessionManager
    @State private var editing: PortForwardRule?
    @State private var error: String?

    private var profile: ServerProfile? { store.servers.first { $0.id == hostID } }

    var body: some View {
        Section {
            ForEach(profile?.portForwards ?? []) { rule in
                PortForwardRow(rule: rule, connection: manager.connection(for: hostID))
                    .swipeActions {
                        Button("删除", role: .destructive) { remove(rule) }
                        Button("编辑") { editing = rule }.tint(.blue)
                    }
            }
            Button {
                editing = PortForwardRule(localPort: 8080, remoteHost: "127.0.0.1", remotePort: 80)
            } label: {
                Label("添加转发", systemImage: "plus")
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("端口转发")
        } footer: {
            Text("在本机 127.0.0.1 上监听，经 SSH 转发到服务器可访问的地址（如内网主机）。App 在前台时有效。")
        }
        .sheet(item: $editing) { rule in
            PortForwardEditView(rule: rule) { save($0) }
        }
    }

    private func save(_ rule: PortForwardRule) {
        guard var profile else { return }
        if let index = profile.portForwards.firstIndex(where: { $0.id == rule.id }) {
            profile.portForwards[index] = rule
            manager.connection(for: hostID).stopForward(rule.id) // 规则变化后需重新启动
        } else {
            profile.portForwards.append(rule)
        }
        persist(profile)
    }

    private func remove(_ rule: PortForwardRule) {
        guard var profile else { return }
        manager.connection(for: hostID).stopForward(rule.id)
        profile.portForwards.removeAll { $0.id == rule.id }
        persist(profile)
    }

    private func persist(_ profile: ServerProfile) {
        do {
            try store.save(profile, secret: nil)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PortForwardRow: View {
    let rule: PortForwardRule
    @ObservedObject var connection: HostConnection

    private var state: HostConnection.ForwardState? { connection.forwardStates[rule.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { state != nil && !isFailed },
                set: { $0 ? connection.startForward(rule) : connection.stopForward(rule.id) }
            )) {
                Text(rule.summary).font(.callout.monospaced()).lineLimit(1).minimumScaleFactor(0.7)
            }
            switch state {
            case .starting:
                Text("正在启动…").font(.caption).foregroundStyle(.secondary)
            case .running(let connections):
                Text("运行中 · \(connections) 个连接").font(.caption).foregroundStyle(.green)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red)
            case nil:
                EmptyView()
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}

struct PortForwardEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rule: PortForwardRule
    @State private var localPort: String
    @State private var remotePort: String
    @State private var error: String?
    let onSave: (PortForwardRule) -> Void

    init(rule: PortForwardRule, onSave: @escaping (PortForwardRule) -> Void) {
        _rule = State(initialValue: rule)
        _localPort = State(initialValue: String(rule.localPort))
        _remotePort = State(initialValue: String(rule.remotePort))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("本机") {
                    TextField("本地端口（1024–65535）", text: $localPort).keyboardType(.numberPad)
                }
                Section("目标（从服务器视角）") {
                    TextField("地址，例如 10.0.0.5 或 127.0.0.1", text: $rule.remoteHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("端口", text: $remotePort).keyboardType(.numberPad)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("端口转发")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
            }
        }
    }

    private func save() {
        guard let local = Int(localPort), let remote = Int(remotePort) else {
            error = "端口必须是数字"
            return
        }
        var result = rule
        result.localPort = local
        result.remotePort = remote
        result.remoteHost = result.remoteHost.trimmingCharacters(in: .whitespaces)
        if let message = result.validationError() {
            error = message
            return
        }
        onSave(result)
        dismiss()
    }
}
