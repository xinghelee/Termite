import SwiftUI

/// ⌘O 目录跳转器:模糊搜索去过的目录(frecency 排序),回车让当前 shell cd 过去;
/// 无活跃会话则在该目录开新标签。
struct DirectoryJumperView: View {
    @Environment(SessionManager.self) private var sessionManager

    @State private var query = ""
    @State private var selectionIndex = 0
    @State private var history = DirectoryHistory.shared

    private var controller: CommandPaletteController { sessionManager.directoryJumper }

    private var rows: [DirectoryHistory.Entry] {
        history.query(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundStyle(.secondary)
                PaletteTextField(
                    text: $query,
                    placeholder: String(localized: "跳转到去过的目录…"),
                    onMoveUp: { selectionIndex = max(selectionIndex - 1, 0) },
                    onMoveDown: { selectionIndex = min(selectionIndex + 1, max(rows.count - 1, 0)) },
                    onSubmit: { activate() },
                    onCancel: { controller.dismiss() }
                )
                .frame(height: 22)
            }
            .padding(14)

            if rows.isEmpty {
                Divider()
                Text(query.isEmpty ? "目录历史为空 —— cd 到处走走,这里会记住(需 shell 集成)" : "无匹配目录")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(14)
            } else {
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
                    .frame(maxHeight: 360)
                    .onChange(of: selectionIndex) { _, i in
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(i, anchor: .center) }
                    }
                }
                Divider()
                Text("回车 cd · 按访问频率与新近度排序")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            }
        }
        .frame(width: 580)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .onAppear { query = ""; selectionIndex = 0 }
        .onChange(of: query) { _, _ in selectionIndex = 0 }
    }

    @ViewBuilder
    private func rowView(_ entry: DirectoryHistory.Entry, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(entry.name)
            Text(entry.displayPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(entry.visits)×")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }

    private func activate() {
        guard rows.indices.contains(selectionIndex) else { return }
        let entry = rows[selectionIndex]
        controller.dismiss()
        DirectoryHistory.shared.record(path: entry.path)
        if let session = sessionManager.selected {
            // ^U 清掉输入行上可能敲了一半的内容,再发 cd
            session.sendText("\u{15}cd " + TermiteTerminalView.shellEscaped(entry.path) + "\n")
            session.focusTerminal()
        } else {
            sessionManager.newTab(directory: entry.path)
        }
    }
}
