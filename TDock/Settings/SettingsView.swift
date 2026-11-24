import SwiftUI
import TDockCore

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var lock: AppLock
    @ObservedObject private var sync = CloudSync.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("终端外观") {
                    Picker("主题", selection: $settings.themeID) {
                        ForEach(TerminalTheme.builtIn) { theme in
                            ThemeLabel(theme: theme).tag(theme.id)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    VStack(alignment: .leading) {
                        HStack {
                            Text("字号")
                            Spacer()
                            Text("\(Int(settings.fontSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.fontSize, in: TerminalTheme.fontSizeRange, step: 1)
                    }
                    ThemePreview(theme: settings.theme, fontSize: settings.fontSize)
                        .listRowInsets(EdgeInsets())
                }

                Section("键盘") {
                    NavigationLink("自定义快捷栏") { ShortcutEditorView() }
                    NavigationLink("指令片段") { SnippetEditorView() }
                }

                Section {
                    NavigationLink("文件备份与恢复") { ServerBackupView() }
                } header: {
                    Text("备份与迁移")
                } footer: {
                    Text("手动导出、导入服务器配置，可通过 iCloud 云盘或 AirDrop 传递文件。与下方的 iCloud 自动同步独立，不需要 App 的 iCloud 授权。")
                }

                Section {
                    Toggle("打开 App 时需要 Face ID", isOn: Binding(
                        get: { settings.faceIDEnabled },
                        set: { lock.setEnabled($0) }
                    ))
                    Toggle("后台隐藏屏幕内容", isOn: Binding(
                        get: { settings.shouldObscureWhenInactive },
                        set: { settings.privacyScreenEnabled = $0 }
                    ))
                        .disabled(settings.faceIDEnabled)
                    if let error = lock.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    NavigationLink("密钥库") { KeysView() }
                    NavigationLink("已信任主机（Known Hosts）") { KnownHostsView() }
                } header: {
                    Text("安全")
                } footer: {
                    Text("“后台隐藏屏幕内容”：进入多任务切换器或下拉通知中心时用毛玻璃遮住终端内容（开启 Face ID 锁时总是生效）。密码与私钥只保存在本机 Keychain，不会同步到 iCloud。")
                }

                Section {
                    Toggle("通过 iCloud 同步服务器配置", isOn: Binding(
                        get: { settings.iCloudSyncEnabled && sync.canUseICloud },
                        set: { settings.iCloudSyncEnabled = $0 }
                    ))
                    .disabled(!sync.canUseICloud)
                    Label(sync.status.title, systemImage: sync.status.symbol)
                        .foregroundStyle(sync.status.isProblem ? Color.orange : Color.secondary)
                        .accessibilityIdentifier("cloudSyncStatus")
                    Text(sync.status.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if sync.canUseICloud {
                        LabeledContent("最近提交给系统") {
                            if let date = sync.lastSubmittedAt {
                                Text(date, style: .time)
                            } else {
                                Text("本次打开后暂无提交")
                            }
                        }
                        LabeledContent("最近收到云端更新") {
                            if let date = sync.lastReceivedAt {
                                Text(date, style: .time)
                            } else {
                                Text("本次打开后尚未收到")
                            }
                        }
                    }
                    if sync.isConfigured {
                        Button("重新检查同步状态") { sync.refresh() }
                    }
                } header: {
                    Text("同步")
                } footer: {
                    Text("通过同一 Apple 账户同步服务器配置。iCloud 由系统异步处理，提交请求不代表其他设备已收到。密码和私钥始终只保存在本机，新设备需重新填写。")
                }
            }
            .navigationTitle("设置")
            .onAppear { sync.refresh() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}

private struct ThemeLabel: View {
    let theme: TerminalTheme

    var body: some View {
        HStack {
            HStack(spacing: 2) {
                ForEach(1..<7) { index in
                    Rectangle().fill(Color(theme.ansi[index])).frame(width: 6, height: 14)
                }
            }
            .padding(3)
            .background(Color(theme.background), in: RoundedRectangle(cornerRadius: 3))
            Text(theme.name)
        }
    }
}

private struct ThemePreview: View {
    let theme: TerminalTheme
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            line([("user@host", 2), (":", 7), ("~/project", 4), ("$ ", 7), ("ls -la", 7)])
            line([("drwxr-xr-x ", 7), ("src", 4), ("  README.md  ", 7), ("build.sh", 2)])
            line([("error: ", 9), ("something failed ", 7), ("warning", 3)])
        }
        .font(.system(size: fontSize, design: .monospaced))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(theme.background))
    }

    private func line(_ parts: [(String, Int)]) -> some View {
        parts.reduce(Text("")) { text, part in
            text + Text(part.0).foregroundColor(part.1 == 7 ? Color(theme.foreground) : Color(theme.ansi[part.1]))
        }
        .lineLimit(1)
    }
}

private extension CloudSync.Status {
    var title: String {
        switch self {
        case .checking: return "正在检查同步条件"
        case .notConfigured: return "当前版本不支持 iCloud 同步"
        case .accountUnavailable: return "iCloud 账户不可用"
        case .disabled: return "同步已关闭"
        case .waiting: return "等待 iCloud 更新"
        case .queued: return "本地配置已提交给系统"
        case .failed: return "同步出现问题"
        }
    }

    var explanation: String {
        switch self {
        case .checking:
            return "正在检查当前安装包与 iCloud 账户的可用状态。"
        case .notConfigured:
            return "此安装包未启用 iCloud 同步授权，仅保存本机配置。需要使用支持 iCloud 的开发者团队重新签名安装；免费个人团队的调试版本无法启用。"
        case .accountUnavailable:
            return "尚未登录 iCloud，或当前账户的 iCloud 服务不可用。请在系统设置中检查 Apple 账户和 iCloud 设置，再返回 App。"
        case .disabled:
            return "配置仅保存在本机。开启后，系统会自动合并同一 Apple 账户下的服务器配置。"
        case .waiting:
            return "已请求系统检查更新，尚不能确认其他设备的同步结果。可在另一台设备修改服务器名称，检查这里是否收到更新。"
        case .queued:
            return "配置已写入本机的 iCloud 缓存，由系统安排上传；这不表示另一台设备已经收到。"
        case .failed(.requestRejected):
            return "系统未接受同步请求，请检查账户、iCloud 授权和网络后重新检查。现有本机配置会保留。"
        case .failed(.quotaExceeded):
            return "服务器配置超过 iCloud 键值存储的可用容量。请减少配置数据后重新检查。"
        case .failed(.invalidRemoteData):
            return "无法读取云端配置，已保留本机数据且未覆盖云端。请检查两台设备是否使用兼容版本。"
        case .failed(.encodingFailed):
            return "无法准备要同步的配置，本机配置仍然保留。请检查配置内容后重试。"
        }
    }

    var isProblem: Bool {
        switch self {
        case .notConfigured, .accountUnavailable, .failed: return true
        default: return false
        }
    }

    var symbol: String {
        switch self {
        case .notConfigured, .disabled: return "icloud.slash"
        case .accountUnavailable, .failed: return "exclamationmark.icloud"
        default: return "arrow.triangle.2.circlepath.icloud"
        }
    }
}
