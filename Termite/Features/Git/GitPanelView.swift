import SwiftUI

/// Git 面板(⌘G):右侧面板两级导航 ——
/// 一级「未提交 | 历史」文件/提交列表,二级 unified diff(hunk 分隔条 + 双列行号)。
struct GitPanelView: View {
    let session: TerminalSession
    let onClose: () -> Void

    @State private var model = GitPanelModel()
    @State private var enlargedDiff = false

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
        // diff 层自动加宽(列表窄导航,diff 需要横向空间)
        .frame(width: model.diffTarget != nil ? 560 : 330)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.diffTarget != nil)
        .background(theme.panelBackground)
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
                    GitDiffContent(hunks: model.diffHunks, fontSize: 12.5)
                }
                .frame(minWidth: 900, idealWidth: 1080, minHeight: 620, idealHeight: 780)
                .background(theme.panelBackground)
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            if model.diffTarget != nil || model.selectedCommit != nil {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { model.goBack() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
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
            Button {
                Task { await model.refresh(cwd: session.workingDirectory, force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("刷新")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
            if model.diffHunks.isEmpty {
                emptyHint(model.isRefreshing ? "" : "没有可显示的改动(可能是二进制文件)")
                    .frame(maxHeight: .infinity)
            } else {
                GitDiffContent(hunks: model.diffHunks, fontSize: 11)
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
            Button {
                copyDiff()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("复制整个 diff(贴给 AI / PR)")
            if enlarged {
                Button {
                    enlargedDiff = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            } else {
                Button {
                    enlargedDiff = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("放大查看")
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
}

// MARK: - 子视图

/// unified diff 内容:hunk 分隔条 + 双列行号 + 绿增红删(面板与放大 sheet 共用)
struct GitDiffContent: View {
    let hunks: [UnifiedDiff.Hunk]
    var fontSize: CGFloat = 11

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(hunks) { hunk in
                    hunkHeader(hunk)
                    ForEach(hunk.lines) { line in
                        diffLine(line)
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
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
            Spacer(minLength: 0)
        }
        .font(.system(size: fontSize - 1, design: .monospaced))
        .foregroundStyle(theme.accentColor.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accentSoft.opacity(0.5))
    }

    private func diffLine(_ line: UnifiedDiff.Line) -> some View {
        HStack(spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: fontSize * 3.4, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: fontSize * 3.4, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(marker(for: line.kind))
                .frame(width: fontSize * 1.4)
                .foregroundStyle(color(for: line.kind))
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .context ? Color.primary.opacity(0.72) : color(for: line.kind))
        }
        .font(.system(size: fontSize, design: .monospaced))
        .padding(.vertical, 0.5)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(for: line.kind))
    }

    private func marker(for kind: UnifiedDiff.LineKind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }

    private func color(for kind: UnifiedDiff.LineKind) -> Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        case .context: return .secondary
        }
    }

    private func background(for kind: UnifiedDiff.LineKind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.10)
        case .removed: return Color.red.opacity(0.10)
        case .context: return .clear
        }
    }
}

/// 文件行:状态色点 + 文件名 + 目录 + ± 统计
private struct GitFileRow: View {
    let change: GitFileChange
    let open: () -> Void
    let revealInFinder: () -> Void

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
            Button("在 Finder 中显示", action: revealInFinder)
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(change.path, forType: .string)
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
