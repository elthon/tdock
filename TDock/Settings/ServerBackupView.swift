import SwiftUI
import TDockCore
import UniformTypeIdentifiers

struct ServerBackupView: View {
    @EnvironmentObject private var store: ServerStore
    @EnvironmentObject private var manager: SessionManager
    @State private var exporting = false
    @State private var importing = false
    @State private var working = false
    @State private var exportDocument: ServerBackupFile?
    @State private var exportCount = 0
    @State private var pending: PendingBackup?
    @State private var completedImport: String?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("本机服务器", value: "\(store.servers.count) 台")
                Button(action: prepareExport) {
                    Label("导出服务器配置", systemImage: "square.and.arrow.up")
                }
                .disabled(working || store.servers.isEmpty)
                Button { importing = true } label: {
                    Label("从文件导入", systemImage: "square.and.arrow.down")
                }
                .disabled(working)
                if working { ProgressView("正在处理文件…") }
            } header: {
                Text("手动文件备份")
            } footer: {
                Text("导出后，在系统“文件”界面选择 iCloud 云盘或本机位置保存。另一台设备打开 TDock，在这里选择同一文件导入。也可以通过 AirDrop 传送文件。")
            }
            Section("文件包含什么") {
                Text("包含服务器地址、端口、用户名、连接与认证方式、分组、置顶及端口转发配置。")
                Text("不包含密码、私钥、密钥库内容或已信任主机指纹。新设备需重新配置凭据，首次连接仍需核对主机指纹。")
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("文件备份与 iCloud 自动同步彼此独立，不需要 App 的 iCloud 授权。文件保存到哪里由你选择，App 不会在后台自动更新它。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("文件备份与恢复")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: exportFilename) { result in
            switch result {
            case .success:
                message = "已导出 \(exportCount) 台服务器的配置，不含密码或私钥。"
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
            }
            exportDocument = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): readImport(url)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
            }
        }
        .sheet(item: $pending, onDismiss: {
            if let completedImport {
                message = completedImport
                self.completedImport = nil
            }
        }) { item in
            BackupImportPreview(backup: item.backup, filename: item.filename) { policy in
                let plan = try store.importBackup(item.backup, policy: policy)
                manager.disconnectImportedProfiles(plan.updatedIDs)
                completedImport = "导入完成：新增 \(plan.addedIDs.count) 台，更新 \(plan.updatedIDs.count) 台，跳过 \(plan.skipped) 台。新设备上的密码或私钥需重新填写。"
                pending = nil
            }
        }
        .alert("文件备份与恢复", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private var exportFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "TDock-Servers-\(formatter.string(from: Date()))"
    }

    private func prepareExport() {
        let snapshot = ServerBackup(servers: store.servers)
        working = true
        Task {
            defer { working = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) { try snapshot.encoded() }.value
                exportCount = snapshot.servers.count
                exportDocument = ServerBackupFile(data: data)
                exporting = true
            } catch { message = error.localizedDescription }
        }
    }

    private func readImport(_ url: URL) {
        working = true
        Task {
            defer { working = false }
            do {
                let backup = try await Task.detached(priority: .userInitiated) { try ServerBackupFiles.read(url) }.value
                pending = PendingBackup(backup: backup, filename: url.lastPathComponent)
            } catch { message = error.localizedDescription }
        }
    }
}

private struct PendingBackup: Identifiable {
    let id = UUID()
    let backup: ServerBackup
    let filename: String
}

private struct BackupImportPreview: View {
    let backup: ServerBackup
    let filename: String
    let confirm: (ServerBackup.ConflictPolicy) throws -> Void
    @EnvironmentObject private var store: ServerStore
    @Environment(\.dismiss) private var dismiss
    @State private var policy: ServerBackup.ConflictPolicy = .keepLocal
    @State private var error: String?

    private var plan: ServerBackup.ImportPlan? { try? backup.importPlan(current: store.servers, policy: policy) }

    var body: some View {
        let preview = plan
        return NavigationStack {
            List {
                Section {
                    LabeledContent("文件", value: filename)
                    LabeledContent("导出时间") { Text(backup.exportedAt, format: .dateTime) }
                    Picker("已有配置", selection: $policy) {
                        Text("保留本机配置").tag(ServerBackup.ConflictPolicy.keepLocal)
                        Text("使用文件配置更新").tag(ServerBackup.ConflictPolicy.useFile)
                    }
                    if let plan = preview {
                        Text("新增 \(plan.addedIDs.count) 台 · 更新 \(plan.updatedIDs.count) 台 · 跳过 \(plan.skipped) 台")
                        if !plan.updatedIDs.isEmpty {
                            Text("更新配置会关闭对应的本机终端与转发连接。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if !plan.credentialResetIDs.isEmpty {
                            Text("其中 \(plan.credentialResetIDs.count) 台的连接目标或认证方式已变化，需要重新填写本机凭据。")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    Text("合并导入，不删除其他服务器。重复导入同一份备份不会重复新增；独立创建的同名配置会分别保留。")
                }
                Section("文件中的服务器") {
                    ForEach(backup.servers) { server in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.displayName).lineLimit(1)
                                Text(verbatim: "\(server.username)@\(server.host):\(server.port)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(action(for: server.id, plan: preview)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("导入预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认导入") {
                        do { try confirm(policy) } catch { self.error = error.localizedDescription }
                    }
                    .disabled(preview?.changedCount == nil || preview?.changedCount == 0)
                }
            }
        }
    }

    private func action(for id: UUID, plan: ServerBackup.ImportPlan?) -> String {
        if plan?.addedIDs.contains(id) == true { return "新增" }
        if plan?.updatedIDs.contains(id) == true { return "更新" }
        return "跳过"
    }
}

struct ServerBackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw ServerBackup.Failure.invalidFormat }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum ServerBackupFiles {
    static func read(_ url: URL) throws -> ServerBackup {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<ServerBackup, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result {
                let handle = try FileHandle(forReadingFrom: readable)
                defer { try? handle.close() }
                var data = Data()
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    data.append(chunk)
                    guard data.count <= ServerBackup.maximumFileSize else { throw ServerBackup.Failure.tooLarge }
                }
                return try ServerBackup.decode(data)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ServerBackup.Failure.invalidFormat }
        return try result.get()
    }
}
