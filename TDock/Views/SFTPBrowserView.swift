import SwiftUI
import TDockCore
import UniformTypeIdentifiers

/// SFTP 文件浏览：目录导航、下载（分享/存储到“文件”）、上传（文件选择器）。
struct SFTPBrowserView: View {
    let hostID: UUID
    @EnvironmentObject private var manager: SessionManager
    @StateObject private var model = SFTPBrowserModel()
    @State private var importing = false

    var body: some View {
        List {
            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("重试") { model.reload() }
                }
            }
            if model.path != "/" {
                Button {
                    model.goUp()
                } label: {
                    Label("上一级", systemImage: "arrow.turn.left.up")
                }
            }
            ForEach(model.entries) { entry in
                Button {
                    model.open(entry)
                } label: {
                    SFTPEntryRow(entry: entry)
                }
                .foregroundStyle(.primary)
            }
        }
        .overlay {
            if model.isLoading && model.entries.isEmpty { ProgressView() }
        }
        .safeAreaInset(edge: .bottom) {
            if let transfer = model.transfer {
                TransferBanner(transfer: transfer)
            }
        }
        .refreshable { model.reload() }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(model.sftp == nil || model.transfer != nil)
                    .accessibilityLabel("上传文件")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.upload(url) }
        }
        .sheet(item: $model.shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .task { await model.connect(manager.connection(for: hostID)) }
        .onDisappear { model.disconnect() }
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
                HStack(spacing: 8) {
                    if !entry.isDirectory, let size = entry.attributes.size {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                    if let date = entry.attributes.modificationDate {
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TransferBanner: View {
    let transfer: SFTPBrowserModel.Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(transfer.isUpload ? "上传" : "下载") \(transfer.name)").font(.footnote).lineLimit(1)
            if let fraction = transfer.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
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
    private(set) var sftp: SFTPClient?

    var title: String { path == "/" ? "/" : (path as NSString).lastPathComponent }

    func connect(_ connection: HostConnection) async {
        guard sftp == nil else { return }
        isLoading = true
        do {
            let client = try await connection.client()
            let sftp = try await client.openSFTP()
            self.sftp = sftp
            path = try await sftp.realPath(".")
            await load()
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func disconnect() {
        sftp?.close()
        sftp = nil
    }

    func reload() {
        Task { await load() }
    }

    func goUp() {
        navigate(to: (path as NSString).deletingLastPathComponent)
    }

    func open(_ entry: SFTPEntry) {
        let target = (path as NSString).appendingPathComponent(entry.name)
        if entry.isDirectory {
            navigate(to: target)
        } else if entry.attributes.isSymlink {
            // 符号链接：指向目录则进入，否则下载。
            Task {
                if let attrs = try? await sftp?.stat(target), attrs.isDirectory {
                    navigate(to: target)
                } else {
                    download(target, name: entry.name)
                }
            }
        } else {
            download(target, name: entry.name)
        }
    }

    private func navigate(to newPath: String) {
        path = newPath.isEmpty ? "/" : newPath
        entries = []
        reload()
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

    private func download(_ remotePath: String, name: String) {
        guard let sftp, transfer == nil else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tdock-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent(name)
        transfer = Transfer(name: name, isUpload: false)
        Task {
            do {
                try await sftp.download(remotePath, to: local) { [weak self] done, total in
                    Task { @MainActor in self?.transfer?.done = done; self?.transfer?.total = total }
                }
                transfer = nil
                shareItem = ShareItem(url: local)
            } catch {
                transfer = nil
                self.error = "下载失败：\(error.localizedDescription)"
            }
        }
    }

    func upload(_ url: URL) {
        guard let sftp, transfer == nil else { return }
        let name = url.lastPathComponent
        let remote = (path as NSString).appendingPathComponent(name)
        transfer = Transfer(name: name, isUpload: true)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try await sftp.upload(url, to: remote) { [weak self] done, total in
                    Task { @MainActor in self?.transfer?.done = done; self?.transfer?.total = total }
                }
                transfer = nil
                await load()
            } catch {
                transfer = nil
                self.error = "上传失败：\(error.localizedDescription)"
            }
        }
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
