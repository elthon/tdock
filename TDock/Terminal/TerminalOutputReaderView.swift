import SwiftUI
import TDockCore
import UIKit

/// 终端全文查看器（类似微信双击放大阅读器）：
/// - 自动提取当前终端的完整历史输出（tmux 会话自动静默执行 `tmux capture-pane` 拉取服务器端 5000 行缓冲）；
/// - 打开默认定位到最底部，支持一键回顶 / 回底；
/// - 关键词不区分大小写实时搜索 + 高亮匹配 + 上一个 / 下一个跳转；
/// - 智能识别 Error / Warning 行，支持“仅看报错”过滤或一键点击跳回全文上下文所在行；
/// - 支持“自动折行 ↔ 横向滚动”切换（看 `docker ps`、`ps aux` 宽表格不乱行）；
/// - 支持“两点范围选行”（点一行设起点、再点一行设终点，解决手机跨多屏拖选容易断的痛点）；
/// - 底部一键复制最后 50 行（喂给 AI 极其高频）、复制全文、粘贴选中内容回终端、或导出为 `.log` 文件。
struct TerminalOutputReaderView: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var document = TerminalOutputDocument(rawText: "")
    @State private var isLoading = true
    @State private var query = ""
    @State private var matches: [TerminalOutputDocument.LineMatch] = []
    @State private var currentMatchIndex = 0
    @State private var filterIssuesOnly = false
    @AppStorage("reader.wordWrap") private var wordWrap = true
    @State private var isSelectingRange = false
    @State private var anchorLine: Int?
    @State private var endLine: Int?
    @State private var scrollTargetLine: Int?
    @State private var toastMessage: String?
    @State private var exportItem: SFTPBrowserModel.ShareItem?

    private var selectedLineRange: ClosedRange<Int>? {
        guard let anchorLine else { return nil }
        let other = endLine ?? anchorLine
        return min(anchorLine, other)...max(anchorLine, other)
    }

    private var visibleLineIndices: [Int] {
        if filterIssuesOnly {
            return document.issueLineIndices
        }
        return Array(document.lines.indices)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controlBar
                Divider()
                if isSelectingRange {
                    rangeSelectionBanner
                    Divider()
                }
                contentArea
                Divider()
                bottomActionBar
            }
            .background(Color(settings.theme.background))
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button {
                            Task { await reload(scrollToEnd: false) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(isLoading)
                        .accessibilityLabel("刷新最新输出")

                        Button {
                            exportLogFile()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(document.lines.isEmpty)
                        .accessibilityLabel("导出为日志文件")
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    Text(toastMessage)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.82), in: Capsule())
                        .padding(.bottom, 64)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .allowsHitTesting(false)
                }
            }
            .sheet(item: $exportItem) { item in
                ShareSheet(items: [item.url])
            }
            .task {
                await reload(scrollToEnd: true)
            }
            .onChange(of: query) { newQuery in
                updateSearch(newQuery)
            }
        }
    }

    private var navigationTitle: String {
        switch document.source {
        case .localBuffer:
            return "\(session.title) · \(document.totalLines) 行"
        case .tmux(let name):
            return "tmux:\(name) · \(document.totalLines) 行"
        }
    }

    // MARK: - Top Control & Search Bar

    private var controlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索输出内容…", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { stepMatch(1) }
                    if !query.isEmpty {
                        Text(matches.isEmpty ? "0/0" : "\(currentMatchIndex + 1)/\(matches.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(matches.isEmpty ? .red : .secondary)
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 9))

                if !matches.isEmpty {
                    HStack(spacing: 4) {
                        Button { stepMatch(-1) } label: {
                            Image(systemName: "chevron.up")
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("上一个匹配")

                        Button { stepMatch(1) } label: {
                            Image(systemName: "chevron.down")
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("下一个匹配")
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Error / Warning 智能过滤胶囊
                    let issueTotal = document.issueLineIndices.count
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            filterIssuesOnly.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: filterIssuesOnly ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                            if document.errorCount > 0 || document.warningCount > 0 {
                                Text("异常 (\(issueTotal))")
                            } else {
                                Text("无报错")
                            }
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(filterIssuesOnly ? .white : (issueTotal > 0 ? .orange : .secondary))
                        .background(
                            filterIssuesOnly ? Color.orange : Color(uiColor: .secondarySystemFill),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(issueTotal == 0 && !filterIssuesOnly)

                    // 两点范围选行模式
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isSelectingRange.toggle()
                            if !isSelectingRange {
                                anchorLine = nil
                                endLine = nil
                            }
                        }
                    } label: {
                        Label(isSelectingRange ? "退出选行" : "范围选行", systemImage: "checklist")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(isSelectingRange ? .white : .primary)
                            .background(
                                isSelectingRange ? Color.accentColor : Color(uiColor: .secondarySystemFill),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)

                    // 自动折行 vs 横向滚动
                    Button {
                        wordWrap.toggle()
                    } label: {
                        Label(wordWrap ? "自动折行" : "横向滚动",
                              systemImage: wordWrap ? "text.alignleft" : "arrow.left.and.right.text.vertical")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(.primary)
                            .background(Color(uiColor: .secondarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    // 顶部 / 底部跳转
                    Button {
                        if let first = visibleLineIndices.first { scrollTargetLine = first }
                    } label: {
                        Label("顶部", systemImage: "arrow.up.to.line")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(uiColor: .secondarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        if let last = visibleLineIndices.last { scrollTargetLine = last }
                    } label: {
                        Label("底部", systemImage: "arrow.down.to.line")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(uiColor: .secondarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Range Selection Banner

    private var rangeSelectionBanner: some View {
        HStack {
            Image(systemName: "hand.tap")
                .foregroundStyle(Color.accentColor)
            if let range = selectedLineRange {
                Text("已选第 \(range.lowerBound + 1)–\(range.upperBound + 1) 行（共 \(range.count) 行）")
                    .font(.caption.weight(.medium))
            } else {
                Text("先点击起始行，再滚动点击结束行，即可精准选中跨屏段落")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selectedLineRange != nil {
                Button("重选") {
                    anchorLine = nil
                    endLine = nil
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.12))
    }

    // MARK: - Main Content Area

    @ViewBuilder
    private var contentArea: some View {
        if isLoading && document.lines.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在提取终端输出…").font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if document.lines.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "text.page.slash").font(.largeTitle).foregroundStyle(.secondary)
                Text("当前终端暂无输出内容").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleLineIndices.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal").font(.largeTitle).foregroundStyle(.green)
                Text("没有检测到 Error 或 Warning 行").foregroundStyle(.secondary)
                Button("显示全部 \(document.totalLines) 行") { filterIssuesOnly = false }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                Group {
                    if wordWrap {
                        linesScrollView
                    } else {
                        ScrollView(.horizontal, showsIndicators: true) {
                            linesScrollView
                                .frame(minWidth: 1100, alignment: .leading)
                        }
                    }
                }
                .onChange(of: scrollTargetLine) { target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    scrollTargetLine = nil
                }
            }
        }
    }

    private var linesScrollView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleLineIndices, id: \.self) { lineIndex in
                    lineRow(lineIndex)
                        .id(lineIndex)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func lineRow(_ index: Int) -> some View {
        let line = document.lines[index]
        let issue = document.lineIssues[index]
        let inRange = selectedLineRange?.contains(index) == true
        let isCurrentMatchLine = !matches.isEmpty && matches[currentMatchIndex].lineIndex == index

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            // 行号栏
            Text("\(index + 1)")
                .font(.system(size: max(11, settings.fontSize - 2), design: .monospaced))
                .foregroundStyle(isCurrentMatchLine ? Color.yellow : Color.secondary.opacity(0.65))
                .frame(minWidth: 40, alignment: .trailing)

            // 行内容（支持搜索高亮与自由长按选词）
            highlightedLineText(line, lineIndex: index, issue: issue)
                .font(.system(size: settings.fontSize, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: !wordWrap, vertical: true)
                .textSelection(.enabled)

            // 在“仅看异常”模式下，点击右侧箭头跳回全文该行的上下文
            if filterIssuesOnly {
                Button {
                    filterIssuesOnly = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        scrollTargetLine = index
                    }
                } label: {
                    Text("上下文")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(rowBackground(index: index, issue: issue, inRange: inRange, isCurrentMatchLine: isCurrentMatchLine))
        .contentShape(Rectangle())
        .onTapGesture {
            handleLineTap(index)
        }
    }

    private func rowBackground(index: Int, issue: TerminalOutputDocument.IssueKind?, inRange: Bool, isCurrentMatchLine: Bool) -> Color {
        if inRange {
            return Color.accentColor.opacity(0.26)
        }
        if isCurrentMatchLine {
            return Color.yellow.opacity(0.22)
        }
        switch issue {
        case .error:
            return Color.red.opacity(0.14)
        case .warning:
            return Color.orange.opacity(0.12)
        case nil:
            return .clear
        }
    }

    private func highlightedLineText(_ line: String, lineIndex: Int, issue: TerminalOutputDocument.IssueKind?) -> Text {
        let baseColor: Color = {
            switch issue {
            case .error: return Color(red: 1.0, green: 0.45, blue: 0.45)
            case .warning: return Color.orange
            case nil: return Color(settings.theme.foreground)
            }
        }()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !line.isEmpty else {
            return Text(line.isEmpty ? " " : line).foregroundColor(baseColor)
        }

        let nsLine = line as NSString
        var cursor = 0
        var composed = Text("")
        while cursor < nsLine.length {
            let searchRange = NSRange(location: cursor, length: nsLine.length - cursor)
            let found = nsLine.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else {
                let tail = nsLine.substring(from: cursor)
                composed = composed + Text(tail).foregroundColor(baseColor)
                break
            }
            if found.location > cursor {
                let prefix = nsLine.substring(with: NSRange(location: cursor, length: found.location - cursor))
                composed = composed + Text(prefix).foregroundColor(baseColor)
            }
            let matchedText = nsLine.substring(with: found)
            composed = composed + Text(matchedText).bold().underline().foregroundColor(.yellow)
            cursor = found.location + found.length
        }
        return composed
    }

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        HStack(spacing: 10) {
            if let range = selectedLineRange {
                Button {
                    let text = document.text(fromLine: range.lowerBound, toLine: range.upperBound)
                    copyToPasteboard(text, toast: "已复制选中的 \(range.count) 行")
                } label: {
                    Label("复制所选 (\(range.count)行)", systemImage: "doc.on.doc.fill")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)

                Button {
                    let text = document.text(fromLine: range.lowerBound, toLine: range.upperBound)
                    pasteBackToTerminal(text)
                } label: {
                    Label("粘贴回终端", systemImage: "arrow.uturn.backward.circle")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    let count = min(50, document.totalLines)
                    copyToPasteboard(document.tailText(lines: 50), toast: "已复制最后 \(count) 行")
                } label: {
                    Label("复制最后 50 行", systemImage: "doc.on.doc")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
                .disabled(document.lines.isEmpty)

                Button {
                    copyToPasteboard(document.fullText, toast: "已复制全部 \(document.totalLines) 行")
                } label: {
                    Label("复制全文", systemImage: "doc.on.clipboard")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
                .disabled(document.lines.isEmpty)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Logic

    private func reload(scrollToEnd: Bool) async {
        isLoading = true
        let captured = await session.captureOutputDocument()
        document = captured
        isLoading = false
        updateSearch(query)
        if scrollToEnd, let last = visibleLineIndices.last {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                scrollTargetLine = last
            }
        }
    }

    private func updateSearch(_ newQuery: String) {
        matches = document.search(newQuery)
        currentMatchIndex = matches.isEmpty ? 0 : matches.count - 1 // 默认先定位到最靠近底部的最新匹配
        if !matches.isEmpty {
            scrollTargetLine = matches[currentMatchIndex].lineIndex
        }
    }

    private func stepMatch(_ delta: Int) {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + delta + matches.count) % matches.count
        scrollTargetLine = matches[currentMatchIndex].lineIndex
    }

    private func handleLineTap(_ index: Int) {
        if !isSelectingRange {
            // 非选行模式下：如果点击某一行，也可以快捷开启选行并将该行设为起点
            return
        }
        if anchorLine == nil || (anchorLine != nil && endLine != nil) {
            anchorLine = index
            endLine = nil
        } else {
            endLine = index
        }
    }

    private func copyToPasteboard(_ text: String, toast: String) {
        UIPasteboard.general.string = text
        withAnimation { toastMessage = toast }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation {
                if toastMessage == toast { toastMessage = nil }
            }
        }
    }

    private func pasteBackToTerminal(_ text: String) {
        UIPasteboard.general.string = text
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            session.terminalView.paste(nil)
        }
    }

    private func exportLogFile() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tdock-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeTitle = session.title.replacingOccurrences(of: "/", with: "-")
        let fileURL = dir.appendingPathComponent("\(safeTitle)-\(Int(Date().timeIntervalSince1970)).log")
        try? Data(document.fullText.utf8).write(to: fileURL, options: .atomic)
        exportItem = SFTPBrowserModel.ShareItem(url: fileURL)
    }
}
