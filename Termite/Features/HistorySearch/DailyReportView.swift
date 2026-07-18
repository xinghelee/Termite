import SwiftUI

/// 自动日报:今天的命令活动 + 各仓库今日提交,汇成 Markdown 一键复制(standup 神器)
struct DailyReportView: View {
    let onClose: () -> Void

    @State private var markdown: String?
    @State private var copied = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("今日工作日报", systemImage: "doc.text")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    if let markdown {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(markdown, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            copied = false
                        }
                    }
                } label: {
                    Label(copied ? "已复制" : "复制 Markdown", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .disabled(markdown == nil)
                PanelIconButton(symbol: "xmark", help: String(localized: "关闭"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().overlay(theme.borderColor)
            if let markdown {
                ScrollView {
                    Text(markdown)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 620, idealWidth: 720, maxWidth: .infinity, minHeight: 460, idealHeight: 580, maxHeight: .infinity)
        .background(theme.panelBackground)
        .task {
            markdown = await DailyReport.generate()
        }
    }
}

/// 日报生成:命令历史 + 各仓库今日 git log
enum DailyReport {

    static func generate() async -> String {
        let entries = CommandHistoryStore.shared.today()
        let dateText = Date().formatted(date: .abbreviated, time: .omitted)
        var lines: [String] = ["# 工作日报 · \(dateText)", ""]

        if entries.isEmpty {
            lines.append("(今天还没有命令记录)")
            return lines.joined(separator: "\n")
        }

        // 概览
        let failures = entries.filter { ($0.exitCode ?? 0) != 0 }
        let dirs = Dictionary(grouping: entries, by: \.cwd)
        lines.append("## 概览")
        lines.append("- 命令:\(entries.count) 条(失败 \(failures.count))")
        lines.append("- 覆盖目录:\(dirs.count) 个")
        if let first = entries.first, let last = entries.last {
            let clock: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
            lines.append("- 时间段:\(clock(first.timestamp)) – \(clock(last.timestamp))")
        }
        lines.append("")

        // 活跃目录(按命令数)
        lines.append("## 活跃目录")
        for (dir, list) in dirs.sorted(by: { $0.value.count > $1.value.count }).prefix(8) {
            let branch = list.compactMap(\.branch).last.map { " ⎇ \($0)" } ?? ""
            lines.append("- \((dir as NSString).abbreviatingWithTildeInPath)\(branch) — \(list.count) 条命令")
        }
        lines.append("")

        // 各仓库今日提交
        let repoRoots = await resolveRepoRoots(from: Array(dirs.keys))
        if !repoRoots.isEmpty {
            lines.append("## 今日提交")
            for root in repoRoots {
                let log = await GitService.run(
                    ["log", "--since=midnight", "--oneline", "--no-decorate", "-20"],
                    in: root
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !log.isEmpty else { continue }
                lines.append("### \((root as NSString).lastPathComponent)")
                for commit in log.components(separatedBy: "\n") {
                    lines.append("- \(commit)")
                }
            }
            lines.append("")
        }

        // 失败命令(排查线索)
        if !failures.isEmpty {
            lines.append("## 失败命令")
            for failure in failures.suffix(8) {
                lines.append("- `\(failure.command.prefix(80))`(exit \(failure.exitCode ?? -1))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 目录集合 → 去重后的仓库根(上限 6 个,避免日报生成过慢)
    private static func resolveRepoRoots(from dirs: [String]) async -> [String] {
        var roots: Set<String> = []
        for dir in dirs {
            guard roots.count < 6 else { break }
            guard FileManager.default.fileExists(atPath: dir) else { continue }
            if let root = await GitService.run(["rev-parse", "--show-toplevel"], in: dir)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty {
                roots.insert(root)
            }
        }
        return roots.sorted()
    }
}
