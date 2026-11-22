import SwiftUI
import TDockCore

/// 设置 → 安全 → 已信任主机：查看主机密钥指纹，滑动删除（下次连接时重新确认）。
struct KnownHostsView: View {
    private let store = KnownHostsStore.shared
    @State private var entries: [KnownHostEntry] = []
    @State private var pendingDelete: KnownHostEntry?

    var body: some View {
        List {
            if entries.isEmpty {
                Text("还没有已信任的主机。首次连接某台服务器并确认指纹后会记录在这里。")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: entry.port == 22 ? entry.host : "\(entry.host):\(entry.port)")
                        .font(.headline)
                    Text(entry.keyType).font(.caption).foregroundStyle(.secondary)
                    Text(entry.fingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
                .swipeActions {
                    Button("删除", role: .destructive) { pendingDelete = entry }
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = entry.fingerprint
                    } label: {
                        Label("复制指纹", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) { pendingDelete = entry } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("已信任主机")
        .onAppear(perform: reload)
        .confirmationDialog(
            "删除信任记录？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { entry in
            Button("删除 \(entry.host)", role: .destructive) {
                store.remove(entry)
                reload()
            }
        } message: { _ in
            Text("下次连接该主机时会重新显示指纹并要求确认。")
        }
    }

    private func reload() {
        entries = store.allEntries
    }
}
