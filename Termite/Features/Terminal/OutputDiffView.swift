import SwiftUI

/// 输出 Diff:同一条命令两次运行的输出逐行对比(统一视图,绿增红删)
struct OutputDiffView: View {
    let session: TerminalSession
    let current: CommandRecord
    let previous: CommandRecord
    let onClose: () -> Void

    @State private var ops: [LineDiff.Op] = []
    @State private var unavailable = false

    private var theme: TerminalTheme { ThemeStore.shared.current }
    private var stats: (added: Int, removed: Int) { LineDiff.stats(ops) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if unavailable {
                Text("上次的输出已被回滚缓冲修剪,无法对比")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if ops.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 单个 AttributedString:行不换行,横向滚动查看(LazyVStack 会把长行折成一团)
                ScrollView([.vertical, .horizontal]) {
                    Text(attributedDiff)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineSpacing(1)
                        .textSelection(.enabled)
                        .padding(10)
                }
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 380, idealHeight: 520)
        .background(theme.panelBackground)
        .task {
            guard let oldText = session.outputText(of: previous),
                  let newText = session.outputText(of: current) else {
                unavailable = true
                return
            }
            let oldLines = oldText.components(separatedBy: "\n")
            let newLines = newText.components(separatedBy: "\n")
            ops = LineDiff.diff(old: oldLines, new: newLines)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("输出对比", systemImage: "plus.forwardslash.minus")
                    .font(.system(size: 12, weight: .semibold))
                if !ops.isEmpty {
                    Text("+\(stats.added)")
                        .foregroundStyle(.green)
                    Text("−\(stats.removed)")
                        .foregroundStyle(.red)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            }
            .font(.system(size: 11).monospacedDigit())
            Text(current.commandText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            HStack(spacing: 8) {
                Text("上次 \(previous.finishedAt.formatted(date: .omitted, time: .standard))")
                Image(systemName: "arrow.right")
                    .font(.system(size: 8))
                Text("这次 \(current.finishedAt.formatted(date: .omitted, time: .standard))")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(12)
    }

    private var attributedDiff: AttributedString {
        var result = AttributedString()
        for (index, op) in ops.enumerated() {
            let prefix: String
            let text: String
            let color: Color
            var background: Color?
            switch op {
            case .same(let line):
                prefix = "  "; text = line; color = Color.primary.opacity(0.72); background = nil
            case .added(let line):
                prefix = "+ "; text = line; color = .green; background = Color.green.opacity(0.13)
            case .removed(let line):
                prefix = "− "; text = line; color = .red; background = Color.red.opacity(0.13)
            }
            var content = AttributedString(prefix + (text.isEmpty ? " " : text))
            content.foregroundColor = color
            if let background {
                content.backgroundColor = background
            }
            result += content
            if index < ops.count - 1 {
                result += AttributedString("\n")
            }
        }
        return result
    }
}
