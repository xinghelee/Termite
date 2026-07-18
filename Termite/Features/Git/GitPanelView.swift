import SwiftUI

/// Git 面板(⌘G):右侧面板两级导航 ——
/// 一级「未提交 | 历史」文件/提交列表,二级 unified diff(hunk 分隔条 + 双列行号)。
struct GitPanelView: View {
    let session: TerminalSession
    let onClose: () -> Void

    @State private var model = GitPanelModel()
    @State private var enlargedDiff = false
    @State private var fileHistoryTarget: GitFileChange?
    @AppStorage(SettingsKeys.diffWrapLines) private var diffWrap = true
    /// 面板宽度(拖左缘调整,持久化)
    @AppStorage("git.panelWidth") private var storedWidth = 330.0
    @State private var dragStartWidth: Double?
    @Environment(\.openWindow) private var openWindow

    /// diff 层保证最少 520pt
    private var effectiveWidth: CGFloat {
        CGFloat(model.diffTarget != nil ? max(storedWidth, 520) : storedWidth)
    }

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.borderColor)
            if model.repoRoot == nil {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.trianglehead.branch")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("当前目录不在 git 仓库中")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let target = model.diffTarget {
                diffScreen(target)
            } else if let commit = model.selectedCommit {
                commitFilesScreen(commit)
            } else {
                listScreen
            }
        }
        .frame(width: effectiveWidth)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.diffTarget != nil)
        .background(theme.panelBackground)
        // 左缘拖拽调宽
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.clear)
                .frame(width: 7)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragStartWidth == nil { dragStartWidth = Double(effectiveWidth) }
                            let proposed = (dragStartWidth ?? 330) - Double(value.translation.width)
                            storedWidth = min(max(proposed, 280), 980)
                        }
                        .onEnded { _ in dragStartWidth = nil }
                )
        }
        .task(id: session.workingDirectory) {
            await model.refresh(cwd: session.workingDirectory)
        }
        .onChange(of: session.commandHistory.count) { _, _ in
            // 命令(常见 git add/commit)结束后自动刷新
            Task { await model.refresh(cwd: session.workingDirectory) }
        }
        .sheet(isPresented: $enlargedDiff) {
            if let target = model.diffTarget {
                VStack(spacing: 0) {
                    diffHeader(target, enlarged: true)
                    Divider()
                    if target.change.isImage, let root = model.repoRoot {
                        ImageDiffView(change: target.change, commitHash: target.commit?.hash, repoRoot: root)
                    } else {
                        GitDiffContent(hunks: model.diffHunks, fontSize: 12.5, wrap: diffWrap)
                    }
                }
                .frame(minWidth: 900, idealWidth: 1080, maxWidth: .infinity, minHeight: 620, idealHeight: 780, maxHeight: .infinity)
                .background(theme.panelBackground)
            }
        }
        .sheet(item: $fileHistoryTarget) { target in
            if let root = model.repoRoot {
                FileHistoryView(repoRoot: root, change: target) {
                    fileHistoryTarget = nil
                }
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 4) {
            if model.diffTarget != nil || model.selectedCommit != nil {
                PanelIconButton(symbol: "chevron.left", help: String(localized: "返回")) {
                    withAnimation(.easeOut(duration: 0.15)) { model.goBack() }
                }
            }
            Label("Git", systemImage: "arrow.trianglehead.branch")
                .font(.system(size: 12, weight: .semibold))
            if let branch = session.gitBranch {
                Text(branch)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.accentColor)
                    .lineLimit(1)
            }
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
            }
            if let root = model.repoRoot {
                PanelIconButton(symbol: "point.3.connected.trianglepath.dotted", help: String(localized: "图形历史(SourceTree 式)")) {
                    openWindow(id: "git-history", value: root)
                }
            }
            PanelIconButton(symbol: "arrow.clockwise", help: String(localized: "刷新")) {
                Task { await model.refresh(cwd: session.workingDirectory, force: true) }
            }
            PanelIconButton(symbol: "xmark", help: String(localized: "关闭面板"), action: onClose)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - 一级:列表

    private var listScreen: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.mode) {
                Text("未提交").tag(GitPanelModel.Mode.uncommitted)
                Text("历史").tag(GitPanelModel.Mode.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.mode == .uncommitted {
                        uncommittedList
                    } else {
                        historyList
                    }
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private var uncommittedList: some View {
        if model.status.isEmpty {
            emptyHint("工作区干净 ✨")
        } else {
            changeSection("已暂存", model.status.staged)
            changeSection("未暂存", model.status.unstaged)
            changeSection("未跟踪", model.status.untracked)
        }
    }

    @ViewBuilder
    private func changeSection(_ title: String, _ changes: [GitFileChange]) -> some View {
        if !changes.isEmpty {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(changes) { change in
                GitFileRow(change: change) {
                    Task { await model.showDiff(for: change, commit: nil, cwd: session.workingDirectory) }
                } revealInFinder: {
                    revealInFinder(change)
                } showHistory: {
                    fileHistoryTarget = change
                } stageToggle: {
                    Task {
                        if change.kind == .staged {
                            await model.unstage(change, cwd: session.workingDirectory)
                        } else {
                            await model.stage(change, cwd: session.workingDirectory)
                        }
                    }
                } discard: {
                    confirmDiscard(change)
                }
            }
        }
    }

    @ViewBuilder
    private var historyList: some View {
        if model.commits.isEmpty {
            emptyHint("没有提交记录")
        } else {
            ForEach(model.commits) { commit in
                GitCommitRow(commit: commit) {
                    Task { await model.selectCommit(commit, cwd: session.workingDirectory) }
                }
            }
        }
    }

    // MARK: - 二级:提交文件列表

    private func commitFilesScreen(_ commit: GitCommit) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(commit.subject)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(commit.hash)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.accentColor)
                    Text(commit.author)
                    Text(commit.relativeDate)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().overlay(theme.borderColor)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.commitFiles) { change in
                        GitFileRow(change: change) {
                            Task { await model.showDiff(for: change, commit: commit, cwd: session.workingDirectory) }
                        } revealInFinder: {
                            revealInFinder(change)
                        } showHistory: {
                            fileHistoryTarget = change
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - 三级:diff

    private func diffScreen(_ target: GitPanelModel.DiffTarget) -> some View {
        VStack(spacing: 0) {
            diffHeader(target, enlarged: false)
            Divider().overlay(theme.borderColor)
            if target.change.isImage, let root = model.repoRoot {
                ImageDiffView(change: target.change, commitHash: target.commit?.hash, repoRoot: root)
            } else if model.diffHunks.isEmpty {
                emptyHint(model.isRefreshing ? "" : "没有可显示的改动(可能是二进制文件)")
                    .frame(maxHeight: .infinity)
            } else {
                GitDiffContent(hunks: model.diffHunks, fontSize: 11, wrap: diffWrap)
            }
        }
    }

    private func diffHeader(_ target: GitPanelModel.DiffTarget, enlarged: Bool) -> some View {
        let stats = UnifiedDiff.stats(model.diffHunks)
        return HStack(spacing: 6) {
            GitStatusDot(code: target.change.statusCode)
            Text(target.change.fileName)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("+\(stats.added)")
                .foregroundStyle(.green)
            Text("−\(stats.removed)")
                .foregroundStyle(.red)
            Spacer()
            PanelIconButton(
                symbol: "arrow.turn.down.left",
                help: String(localized: "自动换行(关闭则横向滚动)"),
                tint: diffWrap ? theme.accentColor : nil
            ) {
                diffWrap.toggle()
            }
            PanelIconButton(symbol: "clock.arrow.circlepath", help: String(localized: "这个文件的修改历史")) {
                fileHistoryTarget = target.change
            }
            PanelIconButton(symbol: "doc.on.doc", help: String(localized: "复制整个 diff(贴给 AI / PR)")) {
                copyDiff()
            }
            if enlarged {
                PanelIconButton(symbol: "xmark", help: String(localized: "关闭")) {
                    enlargedDiff = false
                }
                .keyboardShortcut(.cancelAction)
            } else {
                PanelIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: String(localized: "放大查看")) {
                    enlargedDiff = true
                }
            }
        }
        .font(.system(size: 10.5).monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func copyDiff() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.diffRawText, forType: .string)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }

    private func revealInFinder(_ change: GitFileChange) {
        guard let root = model.repoRoot else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent(change.path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 丢弃改动:不可撤销,先确认
    private func confirmDiscard(_ change: GitFileChange) {
        let alert = NSAlert()
        alert.messageText = String(localized: "丢弃「\(change.fileName)」的改动?")
        alert.informativeText = change.kind == .untracked
            ? String(localized: "未跟踪文件会被直接删除,不可撤销。")
            : String(localized: "工作区改动会还原到 HEAD 版本,不可撤销。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "丢弃"))
        alert.addButton(withTitle: String(localized: "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.discard(change, cwd: session.workingDirectory) }
    }
}

// MARK: - 模型

@MainActor
@Observable
final class GitPanelModel {
    enum Mode { case uncommitted, history }

    struct DiffTarget {
        let change: GitFileChange
        let commit: GitCommit?
    }

    var mode: Mode = .uncommitted
    private(set) var repoRoot: String?
    private(set) var status = GitStatusSnapshot()
    private(set) var commits: [GitCommit] = []
    private(set) var commitFiles: [GitFileChange] = []
    private(set) var selectedCommit: GitCommit?
    private(set) var diffTarget: DiffTarget?
    private(set) var diffHunks: [UnifiedDiff.Hunk] = []
    private(set) var diffRawText = ""
    private(set) var isRefreshing = false

    @ObservationIgnored private var lastRefreshAt = Date.distantPast

    func refresh(cwd: String?, force: Bool = false) async {
        guard let cwd else { return }
        // 命令连续结束时节流
        guard force || Date().timeIntervalSince(lastRefreshAt) > 1.5 else { return }
        lastRefreshAt = Date()
        isRefreshing = true
        defer { isRefreshing = false }

        let root = await GitService.run(["rev-parse", "--show-toplevel"], in: cwd)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root, !root.isEmpty else {
            repoRoot = nil
            return
        }
        repoRoot = root
        status = await GitService.status(in: root)
        commits = await GitService.log(in: root)
        // 停在提交文件层时同步刷新它
        if let commit = selectedCommit {
            commitFiles = await GitService.commitFiles(hash: commit.hash, in: root)
        }
    }

    func selectCommit(_ commit: GitCommit, cwd: String?) async {
        guard let root = repoRoot else { return }
        selectedCommit = commit
        commitFiles = await GitService.commitFiles(hash: commit.hash, in: root)
    }

    func showDiff(for change: GitFileChange, commit: GitCommit?, cwd: String?) async {
        guard let root = repoRoot else { return }
        diffTarget = DiffTarget(change: change, commit: commit)
        diffHunks = []
        diffRawText = ""
        let text = await GitService.diff(for: change, commitHash: commit?.hash, in: root)
        diffRawText = text
        diffHunks = UnifiedDiff.parse(text)
    }

    func goBack() {
        if diffTarget != nil {
            diffTarget = nil
            diffHunks = []
            diffRawText = ""
        } else if selectedCommit != nil {
            selectedCommit = nil
            commitFiles = []
        }
    }

    // MARK: - 暂存区操作

    func stage(_ change: GitFileChange, cwd: String?) async {
        guard let root = repoRoot else { return }
        await GitService.stage(path: change.path, in: root)
        await refresh(cwd: cwd, force: true)
    }

    func unstage(_ change: GitFileChange, cwd: String?) async {
        guard let root = repoRoot else { return }
        await GitService.unstage(path: change.path, in: root)
        await refresh(cwd: cwd, force: true)
    }

    func discard(_ change: GitFileChange, cwd: String?) async {
        guard let root = repoRoot else { return }
        await GitService.discard(change: change, in: root)
        await refresh(cwd: cwd, force: true)
    }
}

// MARK: - 子视图

/// unified diff 内容:hunk 分隔条 + 双列行号 + 绿增红删(面板与放大 sheet 共用)。
/// 每个 hunk 渲染为单个 AttributedString 文本:行永不换行,靠横向滚动查看,
/// (LazyVStack 在双向 ScrollView 里只给行视口宽度,会把长行折叠成一团)
struct GitDiffContent: View {
    let hunks: [UnifiedDiff.Hunk]
    var fontSize: CGFloat = 11
    /// 自动换行:开 = 纵向滚动内软换行;关 = 横向滚动看原始排版
    var wrap = true

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        if wrap {
            ScrollView(.vertical) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ScrollView([.vertical, .horizontal]) {
                content
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(hunks) { hunk in
                hunkHeader(hunk)
                Text(attributedLines(of: hunk))
                    .font(.system(size: fontSize, design: .monospaced))
                    .lineSpacing(1)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
            }
        }
        .padding(.vertical, 8)
    }

    private func hunkHeader(_ hunk: UnifiedDiff.Hunk) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis")
                .font(.system(size: 8))
            Text("第 \(hunk.oldStart) → \(hunk.newStart) 行")
            if !hunk.header.isEmpty {
                Text(hunk.header)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.system(size: fontSize - 1, design: .monospaced))
        .foregroundStyle(theme.accentColor.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Capsule().fill(theme.accentSoft.opacity(0.5)))
        .padding(.horizontal, 8)
    }

    private func attributedLines(of hunk: UnifiedDiff.Hunk) -> AttributedString {
        var result = AttributedString()
        for (index, line) in hunk.lines.enumerated() {
            var numbers = AttributedString(pad(line.oldNumber) + " " + pad(line.newNumber) + "  ")
            numbers.foregroundColor = Color.primary.opacity(0.28)

            let marker: String
            let color: Color
            var background: Color?
            switch line.kind {
            case .added:
                marker = "+ "; color = .green; background = Color.green.opacity(0.13)
            case .removed:
                marker = "− "; color = .red; background = Color.red.opacity(0.13)
            case .context:
                marker = "  "; color = Color.primary.opacity(0.72); background = nil
            }
            var content = AttributedString(marker + (line.text.isEmpty ? " " : line.text))
            content.foregroundColor = color
            if let background {
                numbers.backgroundColor = background
                content.backgroundColor = background
            }
            result += numbers
            result += content
            if index < hunk.lines.count - 1 {
                result += AttributedString("\n")
            }
        }
        return result
    }

    private func pad(_ number: Int?) -> String {
        let text = number.map(String.init) ?? ""
        return String(repeating: " ", count: max(0, 5 - text.count)) + text
    }
}

/// 文件行:状态色点 + 文件名 + 目录 + ± 统计
private struct GitFileRow: View {
    let change: GitFileChange
    let open: () -> Void
    let revealInFinder: () -> Void
    var showHistory: () -> Void = {}
    /// 未提交文件:悬停出 暂存(+)/ 取消暂存(−)按钮
    var stageToggle: (() -> Void)?
    var discard: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            GitStatusDot(code: change.statusCode)
            Text(change.fileName)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
            if !change.directory.isEmpty {
                Text(change.directory)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if hovering, let stageToggle {
                Button(action: stageToggle) {
                    Image(systemName: change.kind == .staged ? "minus.circle" : "plus.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(change.kind == .staged ? "取消暂存" : "暂存")
            }
            if let added = change.added, let removed = change.removed {
                Text("+\(added)")
                    .foregroundStyle(.green)
                Text("−\(removed)")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 10).monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 4.5)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            Button("查看 Diff", action: open)
            Button("文件修改历史", action: showHistory)
            Button("在 Finder 中显示", action: revealInFinder)
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(change.path, forType: .string)
            }
            if let stageToggle {
                Divider()
                Button(change.kind == .staged ? "取消暂存" : "暂存", action: stageToggle)
            }
            if let discard {
                Button("丢弃改动…", role: .destructive, action: discard)
            }
        }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// 提交行
private struct GitCommitRow: View {
    let commit: GitCommit
    let open: () -> Void

    @State private var hovering = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(commit.subject)
                .font(.system(size: 11.5))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(commit.hash)
                    .foregroundStyle(theme.accentColor)
                Text(commit.author)
                Text(commit.relativeDate)
                Spacer()
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
    }
}

/// 状态码色点:M 黄 / A·? 绿 / D 红 / R·C 蓝 / U 橙
struct GitStatusDot: View {
    let code: String

    private var color: Color {
        switch code {
        case "M": return .yellow
        case "A", "?": return .green
        case "D": return .red
        case "R", "C": return .blue
        case "U": return .orange
        default: return .gray
        }
    }

    var body: some View {
        Text(code)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 13, height: 13)
            .background(Circle().fill(color.opacity(0.18)))
    }
}
