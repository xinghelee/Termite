import SwiftUI

/// ⌘⇧H 全局命令历史搜索:跨会话跨重启,回车把命令插入当前终端(不执行)
struct HistorySearchView: View {
    @Environment(SessionManager.self) private var sessionManager

    @State private var query = ""
    @State private var selectionIndex = 0
    @State private var rows: [CommandHistoryStore.Entry] = []

    private var controller: CommandPaletteController { sessionManager.historySearch }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                PaletteTextField(
                    text: $query,
                    placeholder: String(localized: "搜索命令历史(跨会话)…"),
                    onMoveUp: { selectionIndex = max(selectionIndex - 1, 0) },
                    onMoveDown: { selectionIndex = min(selectionIndex + 1, max(rows.count - 1, 0)) },
                    onSubmit: { activate() },
                    onCancel: { controller.dismiss() }
                )
                .frame(height: 22)
            }
            .padding(14)

            if !rows.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                                rowView(entry, isSelected: index == selectionIndex)
                                    .id(index)
                                    .onHover { if $0 { selectionIndex = index } }
                                    .onTapGesture { selectionIndex = index; activate() }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selectionIndex) { _, i in
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(i, anchor: .center) }
                    }
                }
                Divider()
                Text("回车插入命令(不执行) · 按时间倒序")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            }
        }
        .frame(width: 640)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .onAppear {
            query = ""
            selectionIndex = 0
            rows = CommandHistoryStore.shared.search("")
        }
        .onChange(of: query) { _, newValue in
            selectionIndex = 0
            rows = CommandHistoryStore.shared.search(newValue)
        }
    }

    @ViewBuilder
    private func rowView(_ entry: CommandHistoryStore.Entry, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: (entry.exitCode ?? 0) == 0 ? "checkmark" : "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle((entry.exitCode ?? 0) == 0 ? Color.green : Color.red)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.command)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text((entry.cwd as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let branch = entry.branch {
                        Text("⎇ " + branch)
                    }
                    Text(entry.timestamp.formatted(.relative(presentation: .named)))
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }

    private func activate() {
        guard rows.indices.contains(selectionIndex) else { return }
        let entry = rows[selectionIndex]
        controller.dismiss()
        guard let session = sessionManager.selected else { return }
        // ^U 清掉输入到一半的行,插入历史命令但不回车,交用户确认
        session.sendText("\u{15}" + entry.command)
        session.focusTerminal()
    }
}
