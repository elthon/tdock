import SwiftUI
import TDockCore

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var lock: AppLock
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
                            Text("\(Int(settings.fontSize)) pt").foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $settings.fontSize, in: TerminalTheme.fontSizeRange, step: 1)
                    }
                    ThemePreview(theme: settings.theme, fontSize: settings.fontSize)
                        .listRowInsets(EdgeInsets())
                }

                Section("键盘") {
                    NavigationLink("自定义快捷栏") { ShortcutEditorView() }
                }

                Section {
                    Toggle("打开 App 时需要 Face ID", isOn: Binding(
                        get: { settings.faceIDEnabled },
                        set: { lock.setEnabled($0) }
                    ))
                    if let error = lock.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    NavigationLink("密钥库") { KeysView() }
                } header: {
                    Text("安全")
                } footer: {
                    Text("密码与私钥只保存在本机 Keychain，不会同步到 iCloud。")
                }

                Section {
                    Toggle("通过 iCloud 同步服务器配置", isOn: $settings.iCloudSyncEnabled)
                } header: {
                    Text("同步")
                } footer: {
                    Text("同步主机、端口、用户名、连接方式与端口转发规则。在新设备上首次连接时需要重新填写密码或私钥。")
                }
            }
            .navigationTitle("设置")
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
