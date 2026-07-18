import SwiftUI

/// 结构化输出查看器:上条命令输出嗅探为 JSON/CSV/TSV 时,
/// 状态栏出现入口,点开在不打扰终端流的前提下加一层「透镜」。
struct StructuredOutputView: View {
    let session: TerminalSession
    let record: CommandRecord
    let onClose: () -> Void

    @State private var raw: String?
    @State private var copied = false

    private var theme: TerminalTheme { ThemeStore.shared.current }
    private var format: StructuredOutputFormat { record.structured ?? .json }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let raw {
                switch format {
                case .json:
                    JSONPrettyView(raw: raw)
                case .csv, .tsv:
                    CSVGridView(raw: raw, separator: format.separator)
                }
            } else {
                Text("输出已被回滚缓冲修剪,无法查看")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 620, idealWidth: 760, minHeight: 380, idealHeight: 540)
        .background(theme.panelBackground)
        .onAppear { raw = session.outputText(of: record) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(format.label, systemImage: format.symbol)
                .font(.system(size: 12, weight: .semibold))
            Text(record.commandText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button {
                if let raw {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(raw, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                }
            } label: {
                Label(copied ? "已复制" : "复制原文", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }
}

/// JSON 美化视图:解析后 prettyPrinted + sortedKeys;解析失败原样展示
private struct JSONPrettyView: View {
    let raw: String

    private var pretty: String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let text = String(data: out, encoding: .utf8) else {
            return raw
        }
        return text
    }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(pretty)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// CSV/TSV 网格视图:首行作表头,行数截断保护
private struct CSVGridView: View {
    let raw: String
    let separator: String

    private static let maxRows = 200

    private var rows: [[String]] {
        raw.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .prefix(Self.maxRows + 1)
            .map { $0.components(separatedBy: separator) }
    }

    private var truncated: Bool {
        raw.components(separatedBy: "\n").filter { !$0.isEmpty }.count > Self.maxRows + 1
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView([.vertical, .horizontal]) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                        GridRow {
                            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(.system(size: 11.5, design: .monospaced).weight(index == 0 ? .semibold : .regular))
                                    .foregroundStyle(index == 0 ? Color.primary : Color.primary.opacity(0.8))
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(index == 0 ? Color.primary.opacity(0.08) : (index % 2 == 0 ? Color.primary.opacity(0.03) : .clear))
                    }
                }
                .padding(10)
            }
            if truncated {
                Text("仅显示前 \(Self.maxRows) 行 · 完整内容用「复制原文」")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 5)
            }
        }
        .textSelection(.enabled)
    }
}
