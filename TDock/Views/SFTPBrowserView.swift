import QuickLook
import SwiftUI
import TDockCore
import UniformTypeIdentifiers

/// SFTP 文件浏览：
/// - 顶部路径面包屑（点任一级跳转）+ “前往路径…”；
/// - 菜单：显示/隐藏 . 文件、排序、新建文件夹、上传；搜索过滤当前目录；
/// - 点击小文件（≤ 1 MB）直接 QuickLook 预览，大文件先确认大小再下载；
/// - 传输可取消；文件行支持复制路径、重命名、删除、修改权限。
struct SFTPBrowserView: View {
    let hostID: UUID
    @EnvironmentObject private var manager: SessionManager
    @StateObject private var model = SFTPBrowserModel()
    @AppStorage("sftp.showHidden") private var showHidden = false
    @AppStorage("sftp.sortKey") private var sortKey = SFTPListing.SortKey.name.rawValue
    @AppStorage("sftp.ascending") private var ascending = true
    @State private var query = ""
    @State private var importing = false
    @State private var prompt: Prompt?
    @State private var promptText = ""
    @State private var pendingDelete: SFTPEntry?
    @State private var pendingLargeDownload: SFTPEntry?

    /// 需要输入文本的操作。
    private enum Prompt: Identifiable {
        case goTo
        case newFolder
        case rename(SFTPEntry)
        case chmod(SFTPEntry)

        var id: String {
            switch self {
            case .goTo: return "goto"
            case .newFolder: return "mkdir"
            case .rename(let entry): return "rename-\(entry.name)"
            case .chmod(let entry): return "chmod-\(entry.name)"
            }
        }
    }

    private var visibleEntries: [SFTPEntry] {
        SFTPListing.arrange(model.entries, showHidden: showHidden, query: query,
                            sortBy: SFTPListing.SortKey(rawValue: sortKey) ?? .name, ascending: ascending)
    }

    var body: some View {
        List {
            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("重试") { model.reload() }
                }
            }
            ForEach(visibleEntries) { entry in
                Button {
                    tapped(entry)
                } label: {
                    SFTPEntryRow(entry: entry)
                }
                .foregroundStyle(.primary)
                .swipeActions {
                    Button("删除", role: .destructive) { pendingDelete = entry }
                    Button("重命名") { ask(.rename(entry), prefill: entry.name) }.tint(.blue)
                }
                .swipeActions(edge: .leading) {
                    Button { model.copyPath(of: entry) } label: { Label("复制路径", systemImage: "doc.on.doc") }
                        .tint(.indigo)
                }
                .contextMenu { contextMenu(for: entry) }
            }
            if !model.isLoading && model.error == nil && visibleEntries.isEmpty {
                Text(query.isEmpty ? (model.entries.isEmpty ? "空目录" : "只有隐藏文件（可在右上角菜单中显示）") : "没有匹配的文件")
                    .foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, prompt: "过滤当前目录")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .safeAreaInset(edge: .top, spacing: 0) {
            BreadcrumbBar(path: model.path, navigate: model.navigate(to:), goTo: { ask(.goTo, prefill: model.path) })
        }
        .overlay {
            if model.isLoading && model.entries.isEmpty { ProgressView() }
        }
        .safeAreaInset(edge: .bottom) {
            if let transfer = model.transfer {
                TransferBanner(transfer: transfer, cancel: model.cancelTransfer)
            }
        }
        .refreshable { model.reload() }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { optionsMenu }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.upload(url) }
        }
        .sheet(item: $model.shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .quickLookPreview($model.previewURL)
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField(promptPlaceholder, text: $promptText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("确定") { submitPrompt() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(promptMessage)
        }
        .confirmationDialog(
            "删除？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { entry in
            Button("删除 \(entry.name)", role: .destructive) { model.delete(entry) }
        } message: { entry in
            Text(entry.isDirectory ? "只能删除空目录（SFTP 协议限制）；非空目录请在终端中使用 rm -r。" : "文件将从服务器上永久删除。")
        }
        .confirmationDialog(
            "下载大文件？",
            isPresented: Binding(get: { pendingLargeDownload != nil }, set: { if !$0 { pendingLargeDownload = nil } }),
            titleVisibility: .visible,
            presenting: pendingLargeDownload
        ) { entry in
            Button("下载（\(Self.sizeText(entry.attributes.size))）") { model.download(entry, preview: false) }
        } message: { entry in
            Text("\(entry.name) 大小为 \(Self.sizeText(entry.attributes.size))。下载期间可随时取消。")
        }
        .task { await model.connect(manager.connection(for: hostID)) }
        .onDisappear { model.disconnect() }
    }

    // MARK: - Menus

    private var optionsMenu: some View {
        Menu {
            Section {
                Toggle(isOn: $showHidden) { Label("显示隐藏文件", systemImage: "eye") }
                Picker(selection: $sortKey) {
                    ForEach(SFTPListing.SortKey.allCases, id: \.rawValue) { key in
                        Text(key.title).tag(key.rawValue)
                    }
                } label: {
                    Label("排序方式", systemImage: "arrow.up.arrow.down")
                }
                Toggle(isOn: $ascending) { Label(ascending ? "升序" : "降序", systemImage: "arrow.up") }
            }
            Section {
                Button { ask(.goTo, prefill: model.path) } label: { Label("前往路径…", systemImage: "arrow.right.doc.on.clipboard") }
                Button { ask(.newFolder, prefill: "") } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                    .disabled(model.sftp == nil)
                Button { importing = true } label: { Label("上传文件", systemImage: "square.and.arrow.up") }
                    .disabled(model.sftp == nil || model.transfer != nil)
                Button { model.copyCurrentPath() } label: { Label("复制当前路径", systemImage: "doc.on.doc") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("更多操作")
    }

    @ViewBuilder
    private func contextMenu(for entry: SFTPEntry) -> some View {
        Button { model.copyPath(of: entry) } label: { Label("复制完整路径", systemImage: "doc.on.doc") }
        if !entry.isDirectory {
            Button { model.download(entry, preview: false) } label: { Label("下载 / 分享", systemImage: "square.and.arrow.down") }
                .disabled(model.transfer != nil)
        }
        Button { ask(.rename(entry), prefill: entry.name) } label: { Label("重命名", systemImage: "pencil") }
        Button {
            ask(.chmod(entry), prefill: entry.attributes.permissions.map(SFTPPermissions.octal) ?? "644")
        } label: {
            Label("权限 \(entry.attributes.permissionString)", systemImage: "lock.shield")
        }
        Button(role: .destructive) { pendingDelete = entry } label: { Label("删除", systemImage: "trash") }
    }

    // MARK: - Actions

    private func tapped(_ entry: SFTPEntry) {
        if entry.isDirectory {
            model.navigate(to: SFTPPath.join(model.path, entry.name))
        } else if entry.attributes.isSymlink {
            model.openSymlink(entry)
        } else if let size = entry.attributes.size, size > SFTPListing.previewLimit {
            pendingLargeDownload = entry
        } else {
            model.download(entry, preview: true)
        }
    }

    private func ask(_ kind: Prompt, prefill: String) {
        promptText = prefill
        prompt = kind
    }

    private func submitPrompt() {
        guard let prompt else { return }
        switch prompt {
        case .goTo: model.goTo(promptText)
        case .newFolder: model.makeDirectory(named: promptText)
        case .rename(let entry): model.rename(entry, to: promptText)
        case .chmod(let entry): model.chmod(entry, octal: promptText)
        }
        self.prompt = nil
    }

    private var promptTitle: String {
        switch prompt {
        case .goTo: return "前往路径"
        case .newFolder: return "新建文件夹"
        case .rename: return "重命名"
        case .chmod: return "修改权限"
        case nil: return ""
        }
    }

    private var promptPlaceholder: String {
        switch prompt {
        case .goTo: return "/var/log 或 ~/project"
        case .chmod: return "例如 644、755、600"
        default: return "名称"
        }
    }

    private var promptMessage: String {
        switch prompt {
        case .goTo: return "支持绝对路径、~ 和相对当前目录的路径。"
        case .chmod(let entry): return "\(entry.name) 当前为 \(entry.attributes.permissionString)，输入八进制权限。"
        case .rename(let entry): return "当前名称：\(entry.name)"
        default: return ""
        }
    }

    static func sizeText(_ size: UInt64?) -> String {
        size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "未知大小"
    }
}

/// 可点击、横向滚动的路径面包屑。
private struct BreadcrumbBar: View {
    let path: String
    let navigate: (String) -> Void
    let goTo: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        let crumbs = SFTPPath.breadcrumbs(path)
                        ForEach(Array(crumbs.enumerated()), id: \.element.path) { index, crumb in
                            if index > 1 {
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Button {
                                navigate(crumb.path)
                            } label: {
                                Text(crumb.name)
                                    .font(.footnote.weight(index == crumbs.count - 1 ? .semibold : .regular))
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderless)
                            .disabled(index == crumbs.count - 1)
                            .id(crumb.path)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .onChange(of: path) { newPath in
                    withAnimation { proxy.scrollTo(SFTPPath.normalize(newPath), anchor: .trailing) }
                }
                .onAppear { proxy.scrollTo(SFTPPath.normalize(path), anchor: .trailing) }
            }
            Button(action: goTo) {
                Image(systemName: "arrow.right.circle")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("前往路径")
        }
        .padding(.vertical, 4)
        .background(.bar)
    }
}

private struct SFTPEntryRow: View {
    let entry: SFTPEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : entry.attributes.isSymlink ? "link" : "doc")
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1)
                    .foregroundStyle(entry.name.hasPrefix(".") ? Color.secondary : Color.primary)
                HStack(spacing: 8) {
                    if !entry.isDirectory, let size = entry.attributes.size {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                    if let date = entry.attributes.modificationDate {
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                    }
                    Text(entry.attributes.permissionString).font(.caption.monospaced())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TransferBanner: View {
    let transfer: SFTPBrowserModel.Transfer
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(transfer.isUpload ? "上传" : "下载") \(transfer.name)").lineLimit(1)
                    Spacer()
                    if let total = transfer.total {
                        Text("\(SFTPBrowserView.sizeText(transfer.done)) / \(SFTPBrowserView.sizeText(total))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
                if let fraction = transfer.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            }
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("取消传输")
        }
        .padding()
        .background(.regularMaterial)
    }
}

@MainActor
final class SFTPBrowserModel: ObservableObject {
    struct Transfer: Equatable {
        var name: String
        var isUpload: Bool
        var done: UInt64 = 0
        var total: UInt64?
        var fraction: Double? { total.map { $0 == 0 ? 1 : Double(done) / Double($0) } }
    }

    struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    @Published private(set) var path = "/"
    @Published private(set) var entries: [SFTPEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var transfer: Transfer?
    @Published var shareItem: ShareItem?
    /// QuickLook 预览的本地临时文件。
    @Published var previewURL: URL?
    private(set) var sftp: SFTPClient?
    private var home = "/"
    private var transferTask: Task<Void, Never>?

    var title: String { SFTPPath.lastComponent(path) }

    func connect(_ connection: HostConnection) async {
        guard sftp == nil else { return }
        isLoading = true
        do {
            let client = try await connection.client()
            let sftp = try await client.openSFTP()
            self.sftp = sftp
            home = try await sftp.realPath(".")
            path = home
            await load()
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func disconnect() {
        transferTask?.cancel()
        sftp?.close()
        sftp = nil
    }

    func reload() {
        Task { await load() }
    }

    func navigate(to newPath: String) {
        let normalized = SFTPPath.normalize(newPath)
        guard normalized != path || entries.isEmpty else { return }
        path = normalized
        entries = []
        reload()
    }

    func goTo(_ input: String) {
        navigate(to: SFTPPath.resolve(input, current: path, home: home))
    }

    /// 符号链接：指向目录则进入，否则按文件处理（预览/下载）。
    func openSymlink(_ entry: SFTPEntry) {
        let target = SFTPPath.join(path, entry.name)
        Task {
            if let attrs = try? await sftp?.stat(target) {
                if attrs.isDirectory {
                    navigate(to: target)
                } else {
                    download(entry, preview: (attrs.size ?? 0) <= SFTPListing.previewLimit)
                }
            }
        }
    }

    private func load() async {
        guard let sftp else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await sftp.listDirectory(path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - File operations

    func copyPath(of entry: SFTPEntry) {
        UIPasteboard.general.string = SFTPPath.join(path, entry.name)
    }

    func copyCurrentPath() {
        UIPasteboard.general.string = path
    }

    func makeDirectory(named name: String) {
        perform(validating: name) { sftp, path in
            try await sftp.makeDirectory(SFTPPath.join(path, name.trimmingCharacters(in: .whitespaces)))
        }
    }

    func rename(_ entry: SFTPEntry, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard trimmed != entry.name else { return }
        perform(validating: trimmed) { sftp, path in
            try await sftp.rename(SFTPPath.join(path, entry.name), to: SFTPPath.join(path, trimmed))
        }
    }

    func delete(_ entry: SFTPEntry) {
        perform { sftp, path in
            let target = SFTPPath.join(path, entry.name)
            if entry.isDirectory {
                try await sftp.removeDirectory(target)
            } else {
                try await sftp.remove(target)
            }
        }
    }

    func chmod(_ entry: SFTPEntry, octal: String) {
        guard let permissions = SFTPPermissions.parse(octal) else {
            error = "权限格式不正确：请输入 3–4 位八进制数字，例如 644、755"
            return
        }
        perform { sftp, path in
            try await sftp.setPermissions(SFTPPath.join(path, entry.name), permissions)
        }
    }

    /// 执行一个修改操作，成功后刷新列表；失败时显示错误。
    private func perform(validating name: String? = nil, _ operation: @escaping (SFTPClient, String) async throws -> Void) {
        if let name, let message = SFTPPath.validateName(name) {
            error = message
            return
        }
        guard let sftp else { return }
        let path = self.path
        Task {
            do {
                try await operation(sftp, path)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            await load()
        }
    }

    // MARK: - Transfers

    /// 下载文件。preview = true 时下载后用 QuickLook 预览（QuickLook 内仍可分享/存储），否则弹出分享面板。
    func download(_ entry: SFTPEntry, preview: Bool) {
        guard let sftp, transfer == nil else { return }
        let remote = SFTPPath.join(path, entry.name)
        // 每次下载用独立目录，避免同名文件互相覆盖。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tdock-downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent(entry.name)
        transfer = Transfer(name: entry.name, isUpload: false, total: entry.attributes.size)
        transferTask = Task {
            do {
                try await sftp.download(remote, to: local) { [weak self] done, total in
                    Task { @MainActor in self?.transfer?.done = done; self?.transfer?.total = total }
                }
                transfer = nil
                if preview {
                    previewURL = local
                } else {
                    shareItem = ShareItem(url: local)
                }
            } catch {
                transfer = nil
                try? FileManager.default.removeItem(at: dir)
                if !(error is CancellationError) {
                    self.error = "下载失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func upload(_ url: URL) {
        guard let sftp, transfer == nil else { return }
        let name = url.lastPathComponent
        let remote = SFTPPath.join(path, name)
        transfer = Transfer(name: name, isUpload: true)
        transferTask = Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try await sftp.upload(url, to: remote) { [weak self] done, total in
                    Task { @MainActor in self?.transfer?.done = done; self?.transfer?.total = total }
                }
                transfer = nil
            } catch is CancellationError {
                transfer = nil
                // 远端留下的是不完整的文件，删除它。
                try? await sftp.remove(remote)
            } catch {
                transfer = nil
                self.error = "上传失败：\(error.localizedDescription)"
            }
            await load()
        }
    }

    func cancelTransfer() {
        transferTask?.cancel()
        transferTask = nil
    }
}

/// UIActivityViewController 包装（用于“存储到文件”/分享下载的文件）。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
