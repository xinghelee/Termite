import SwiftUI

/// SourceTree 式图形历史:左侧提交列表(分支泳道图 + refs 徽章 + 作者/时间/hash),
/// 右侧选中提交的文件列表 + diff 预览。
struct GitHistoryGraphView: View {
    let repoRoot: String
    /// 面板 sheet 场景传关闭回调;独立窗口场景为 nil(用系统关闭按钮)
    var onClose: (() -> Void)?

    @State private var rows: [GitGraphRow] = []
    @State private var selectedHash: String?
    @State private var files: [GitFileChange] = []
    @State private var selectedFile: GitFileChange?
    @State private var diffHunks: [UnifiedDiff.Hunk] = []
    @State private var loading = true
    @State private var fileHistoryTarget: GitFileChange?
    /// 全表统一泳道列数(对齐文案列,消除参差)
    @State private var laneColumns = 1
    @AppStorage(SettingsKeys.diffWrapLines) private var diffWrap = true

    private var theme: TerminalTheme { ThemeStore.shared.current }
    private var selectedRow: GitGraphRow? { rows.first { $0.commit.hash == selectedHash } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.borderColor)
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    commitList
                        .frame(minWidth: 480, idealWidth: 620)
                    detailPane
                        .frame(minWidth: 380, idealWidth: 460)
                }
            }
        }
        .frame(minWidth: 980, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
        .background(theme.panelBackground)
        .sheet(item: $fileHistoryTarget) { target in
            FileHistoryView(repoRoot: repoRoot, change: target) {
                fileHistoryTarget = nil
            }
        }
        .task {
            let commits = await GitService.graphLog(in: repoRoot)
            rows = GitGraph.computeRows(commits)
            laneColumns = min(rows.map(\.laneCount).max() ?? 1, 14)
            loading = false
            if let first = rows.first {
                await select(first.commit)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label("提交历史", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12, weight: .semibold))
            Text("\(rows.count) 个提交 · 全部分支")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            if let onClose {
                PanelIconButton(symbol: "xmark", help: String(localized: "关闭"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 左:提交列表

    private var commitList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    GitGraphRowView(
                        row: row,
                        isSelected: row.commit.hash == selectedHash,
                        laneColumns: laneColumns
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task { await select(row.commit) }
                    }
                }
            }
        }
        .background(theme.panelBackground)
    }

    // MARK: - 右:提交详情

    private var detailPane: some View {
        VStack(spacing: 0) {
            if let row = selectedRow {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.commit.subject)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(row.commit.shortHash)
                            .foregroundStyle(theme.accentColor)
                        Text(row.commit.author)
                        Text(row.commit.relativeDate)
                        Spacer()
                        PanelIconButton(
                            symbol: "arrow.turn.down.left",
                            help: String(localized: "自动换行(关闭则横向滚动)"),
                            tint: diffWrap ? theme.accentColor : nil
                        ) {
                            diffWrap.toggle()
                        }
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider().overlay(theme.borderColor)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(files) { change in
                            fileRow(change)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 220)
                Divider().overlay(theme.borderColor)

                if let file = selectedFile, file.isImage {
                    ImageDiffView(change: file, commitHash: selectedHash, repoRoot: repoRoot)
                } else if selectedFile != nil {
                    GitDiffContent(hunks: diffHunks, fontSize: 11, wrap: diffWrap)
                } else {
                    Text("点击上方文件查看 diff")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text("选择一个提交")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.panelBackground)
    }

    private func fileRow(_ change: GitFileChange) -> some View {
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
                Text("+\(added)").foregroundStyle(.green)
                Text("−\(removed)").foregroundStyle(.red)
            }
        }
        .font(.system(size: 10).monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selectedFile?.id == change.id ? theme.accentSoft : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            Task { await showDiff(change) }
        }
        .contextMenu {
            Button("文件修改历史") { fileHistoryTarget = change }
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(change.path, forType: .string)
            }
        }
    }

    // MARK: - 数据

    private func select(_ commit: GraphCommitInfo) async {
        selectedHash = commit.hash
        selectedFile = nil
        diffHunks = []
        files = await GitService.commitFiles(hash: commit.hash, in: repoRoot)
    }

    private func showDiff(_ change: GitFileChange) async {
        selectedFile = change
        guard let hash = selectedHash else { return }
        let text = await GitService.diff(for: change, commitHash: hash, in: repoRoot)
        diffHunks = UnifiedDiff.parse(text)
    }
}

// MARK: - 提交行(泳道图 + 文案列)

private struct GitGraphRowView: View {
    let row: GitGraphRow
    let isSelected: Bool
    /// 全表统一列数:文案列对齐
    var laneColumns = 1

    static let rowHeight: CGFloat = 30
    private static let laneWidth: CGFloat = 13

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        HStack(spacing: 8) {
            GraphCanvas(row: row, laneLimit: laneColumns)
                .frame(width: CGFloat(max(laneColumns, 1)) * Self.laneWidth, height: Self.rowHeight)

            ForEach(row.commit.refs.prefix(3), id: \.self) { ref in
                RefBadge(ref: ref)
            }

            // 长标题截断,不挤压右侧固定列
            Text(row.commit.subject)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text(row.commit.author)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 88, alignment: .trailing)
            Text(row.commit.relativeDate)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 92, alignment: .trailing)
            Text(row.commit.shortHash)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.accentColor.opacity(0.85))
                .lineLimit(1)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(isSelected ? theme.accentSoft : .clear)
    }
}

/// refs 徽章:当前分支强调色、tag 黄、远端灰蓝、本地分支绿
private struct RefBadge: View {
    let ref: String

    private var theme: TerminalTheme { ThemeStore.shared.current }

    private var display: String {
        var name = ref
        if name.hasPrefix("HEAD -> ") { name = String(name.dropFirst("HEAD -> ".count)) }
        if name.hasPrefix("tag: ") { name = String(name.dropFirst("tag: ".count)) }
        // 字符级截断让胶囊贴内容;frame(maxWidth:) 会把胶囊撑开到上限,不能用
        return name.count > 24 ? name.prefix(22) + "…" : name
    }

    private var color: Color {
        if ref.hasPrefix("HEAD") { return theme.accentColor }
        if ref.hasPrefix("tag: ") { return .yellow }
        if ref.contains("/") { return .blue }
        return .green
    }

    var body: some View {
        Text(display)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.16)))
            .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 1))
            .foregroundStyle(color)
    }
}

/// 泳道图画布:直通竖线、汇入/分出曲线、提交点。颜色按泳道号取主题 ANSI 亮色。
/// 竖线上下各越界 8pt(行间同色重叠),任何布局缝隙都不会显出断线;
/// 超出 laneLimit 的泳道直接不画(代替裁剪,避免裁掉越界部分)。
private struct GraphCanvas: View {
    let row: GitGraphRow
    var laneLimit = Int.max

    private static let laneWidth: CGFloat = 13
    private static let overshoot: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let top = -Self.overshoot
            let bottom = size.height + Self.overshoot
            func x(_ lane: Int) -> CGFloat { Self.laneWidth * (CGFloat(lane) + 0.5) }
            func stroke(_ path: Path, lane: Int) {
                context.stroke(path, with: .color(laneColor(lane)), lineWidth: 1.5)
            }

            // 直通竖线
            for lane in row.passThrough where lane < laneLimit {
                var path = Path()
                path.move(to: CGPoint(x: x(lane), y: top))
                path.addLine(to: CGPoint(x: x(lane), y: bottom))
                stroke(path, lane: lane)
            }
            guard row.lane < laneLimit else { return }
            // 上方来线
            if row.hasTopLine {
                var path = Path()
                path.move(to: CGPoint(x: x(row.lane), y: top))
                path.addLine(to: CGPoint(x: x(row.lane), y: midY))
                stroke(path, lane: row.lane)
            }
            // 下方续线
            if row.continuesDown {
                var path = Path()
                path.move(to: CGPoint(x: x(row.lane), y: midY))
                path.addLine(to: CGPoint(x: x(row.lane), y: bottom))
                stroke(path, lane: row.lane)
            }
            // 汇入曲线(上半段:别的泳道 → dot):对称三次贝塞尔,两端切线垂直,跨多泳道也顺滑
            for lane in row.mergesIn where lane < laneLimit {
                var path = Path()
                path.move(to: CGPoint(x: x(lane), y: top))
                path.addLine(to: CGPoint(x: x(lane), y: 0))
                path.addCurve(
                    to: CGPoint(x: x(row.lane), y: midY),
                    control1: CGPoint(x: x(lane), y: midY * 0.55),
                    control2: CGPoint(x: x(row.lane), y: midY * 0.45)
                )
                stroke(path, lane: lane)
            }
            // 分出曲线(下半段:dot → 别的泳道)
            for lane in row.branchesOut where lane < laneLimit {
                let midSegY = (midY + size.height) / 2
                var path = Path()
                path.move(to: CGPoint(x: x(row.lane), y: midY))
                path.addCurve(
                    to: CGPoint(x: x(lane), y: size.height),
                    control1: CGPoint(x: x(row.lane), y: midSegY + 1),
                    control2: CGPoint(x: x(lane), y: midSegY - 1)
                )
                path.addLine(to: CGPoint(x: x(lane), y: bottom))
                stroke(path, lane: lane)
            }
            // 提交点
            let dotRect = CGRect(x: x(row.lane) - 3.5, y: midY - 3.5, width: 7, height: 7)
            context.fill(Path(ellipseIn: dotRect), with: .color(laneColor(row.lane)))
            context.stroke(
                Path(ellipseIn: dotRect.insetBy(dx: -1, dy: -1)),
                with: .color(laneColor(row.lane).opacity(0.35)),
                lineWidth: 1
            )
        }
    }

    /// 泳道配色:主题 ANSI 亮色轮换(蓝/绿/品红/黄/青/红)
    private func laneColor(_ lane: Int) -> Color {
        let theme = ThemeStore.shared.current
        let indices = [12, 10, 13, 11, 14, 9]
        let hex = theme.ansi[indices[lane % indices.count]]
        return Color(nsColor: NSColor(hex: hex))
    }
}
