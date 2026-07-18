import SwiftUI

/// 单文件修改历史:该文件的提交列表 + 每次提交中它的 diff / 图片预览
struct FileHistoryView: View {
    let repoRoot: String
    let change: GitFileChange
    let onClose: () -> Void

    @State private var commits: [GitCommit] = []
    @State private var selectedHash: String?
    @State private var hunks: [UnifiedDiff.Hunk] = []
    @State private var loading = true
    @AppStorage(SettingsKeys.diffWrapLines) private var diffWrap = true

    private var theme: TerminalTheme { ThemeStore.shared.current }

    private var selectedChange: GitFileChange {
        GitFileChange(kind: .committed, statusCode: "M", path: change.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.borderColor)
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if commits.isEmpty {
                Text("没有这个文件的提交记录")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                commitStrip
                Divider().overlay(theme.borderColor)
                if change.isImage {
                    ImageDiffView(change: selectedChange, commitHash: selectedHash, repoRoot: repoRoot)
                } else {
                    GitDiffContent(hunks: hunks, fontSize: 11.5, wrap: diffWrap)
                }
            }
        }
        .frame(minWidth: 760, idealWidth: 900, maxWidth: .infinity, minHeight: 520, idealHeight: 640, maxHeight: .infinity)
        .background(theme.panelBackground)
        .task {
            commits = await GitService.fileLog(path: change.path, in: repoRoot)
            loading = false
            if let first = commits.first {
                await select(first.hash)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label("文件历史", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .semibold))
            Text(change.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(commits.count) 次提交")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
            PanelIconButton(
                symbol: "arrow.turn.down.left",
                help: String(localized: "自动换行"),
                tint: diffWrap ? theme.accentColor : nil
            ) {
                diffWrap.toggle()
            }
            PanelIconButton(symbol: "xmark", help: String(localized: "关闭"), action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 提交横列(时间线式,新在左)
    private var commitStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(commits) { commit in
                    commitChip(commit)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    private func commitChip(_ commit: GitCommit) -> some View {
        let selected = commit.hash == selectedHash
        return Button {
            Task { await select(commit.hash) }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(commit.subject)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
                HStack(spacing: 4) {
                    Text(commit.hash)
                        .foregroundStyle(theme.accentColor)
                    Text(commit.relativeDate)
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 9.5, design: .monospaced))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? theme.accentSoft : theme.elevatedBackground.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? theme.accentColor.opacity(0.4) : theme.borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func select(_ hash: String) async {
        selectedHash = hash
        guard !change.isImage else { return }
        let text = await GitService.run(["show", hash, "--no-color", "--format=", "--", change.path], in: repoRoot) ?? ""
        hunks = UnifiedDiff.parse(text)
    }
}
