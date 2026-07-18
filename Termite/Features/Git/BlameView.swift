import SwiftUI

/// git blame 逐行溯源:每行代码左侧显示引入它的提交/作者/时间,
/// 同一提交连续块共用配色,点击行块跳到该提交在文件历史里的 diff。
struct BlameView: View {
    let repoRoot: String
    let change: GitFileChange
    let onClose: () -> Void

    @State private var lines: [BlameLine] = []
    @State private var loading = true
    @State private var diffTargetHash: String?
    @State private var diffHunks: [UnifiedDiff.Hunk] = []
    @AppStorage(SettingsKeys.diffWrapLines) private var diffWrap = true

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.borderColor)
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lines.isEmpty {
                Text("没有 blame 数据(文件未提交过?)")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let hash = diffTargetHash {
                diffScreen(hash)
            } else {
                blameList
            }
        }
        .frame(minWidth: 860, idealWidth: 1000, maxWidth: .infinity, minHeight: 540, idealHeight: 680, maxHeight: .infinity)
        .background(theme.panelBackground)
        .task {
            let text = await GitService.run(["blame", "--line-porcelain", "--", change.path], in: repoRoot) ?? ""
            lines = BlameParser.parse(text)
            loading = false
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if diffTargetHash != nil {
                PanelIconButton(symbol: "chevron.left", help: String(localized: "返回")) {
                    diffTargetHash = nil
                    diffHunks = []
                }
            }
            Label("Blame", systemImage: "person.text.rectangle")
                .font(.system(size: 12, weight: .semibold))
            Text(change.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            PanelIconButton(symbol: "xmark", help: String(localized: "关闭"), action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var blameList: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    blameRow(line)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func blameRow(_ line: BlameLine) -> some View {
        HStack(spacing: 0) {
            // 提交信息槽:块首行显示,后续行留白;色相由 hash 派生
            Group {
                if line.isBlockStart {
                    HStack(spacing: 6) {
                        Text(String(line.hash.prefix(8)))
                            .foregroundStyle(hashColor(line.hash))
                        Text(line.author)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(line.relativeDate)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(" ")
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .frame(width: 250, alignment: .leading)
            .padding(.leading, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                Task { await showDiff(line.hash) }
            }
            .help("「\(line.summary)」· 点击查看该提交对本文件的改动")

            Rectangle()
                .fill(hashColor(line.hash).opacity(0.75))
                .frame(width: 2.5)

            Text(String(format: "%4d", line.lineNumber))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.28))
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 6)

            Text(line.content.isEmpty ? " " : line.content)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.vertical, 0.5)
        .background(line.isBlockStart ? Color.primary.opacity(0.03) : .clear)
        .textSelection(.enabled)
    }

    private func diffScreen(_ hash: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(String(hash.prefix(10)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.accentColor)
                Text("对 \(change.fileName) 的改动")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider().overlay(theme.borderColor)
            GitDiffContent(hunks: diffHunks, fontSize: 11.5, wrap: diffWrap)
        }
    }

    private func showDiff(_ hash: String) async {
        diffTargetHash = hash
        let text = await GitService.run(["show", hash, "--no-color", "--format=", "--", change.path], in: repoRoot) ?? ""
        diffHunks = UnifiedDiff.parse(text)
    }

    /// hash → 稳定色相(同一提交的块同色)
    private func hashColor(_ hash: String) -> Color {
        var value: UInt32 = 5381
        for byte in hash.utf8.prefix(8) {
            value = value &* 33 &+ UInt32(byte)
        }
        return Color(hue: Double(value % 360) / 360, saturation: 0.55, brightness: 0.85)
    }
}

// MARK: - 数据

struct BlameLine: Identifiable {
    let id: Int
    let hash: String
    let author: String
    let relativeDate: String
    let summary: String
    let lineNumber: Int
    let content: String
    let isBlockStart: Bool
}

enum BlameParser {
    /// `git blame --line-porcelain`:每行一组
    /// "<sha> <orig> <final> [count]" + 若干 "key value" + "\t<内容>"
    static func parse(_ text: String) -> [BlameLine] {
        var result: [BlameLine] = []
        var authors: [String: String] = [:]
        var times: [String: Date] = [:]
        var summaries: [String: String] = [:]

        var currentHash = ""
        var currentLineNumber = 0
        var previousHash = ""

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("\t") {
                let content = String(line.dropFirst())
                let isStart = currentHash != previousHash
                previousHash = currentHash
                let date = times[currentHash]
                result.append(BlameLine(
                    id: result.count,
                    hash: currentHash,
                    author: authors[currentHash] ?? "?",
                    relativeDate: date.map { formatter.localizedString(for: $0, relativeTo: Date()) } ?? "",
                    summary: summaries[currentHash] ?? "",
                    lineNumber: currentLineNumber,
                    content: content,
                    isBlockStart: isStart
                ))
                continue
            }
            let parts = line.components(separatedBy: " ")
            if parts.count >= 3, parts[0].count == 40, Int(parts[2]) != nil {
                currentHash = parts[0]
                currentLineNumber = Int(parts[2]) ?? 0
            } else if line.hasPrefix("author ") {
                authors[currentHash] = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("author-time ") {
                if let epoch = TimeInterval(line.dropFirst("author-time ".count)) {
                    times[currentHash] = Date(timeIntervalSince1970: epoch)
                }
            } else if line.hasPrefix("summary ") {
                summaries[currentHash] = String(line.dropFirst("summary ".count))
            }
        }
        return result
    }
}
