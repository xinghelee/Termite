import SwiftTerm
import SwiftUI

/// scrollback 搜索:走 SwiftTerm 内置搜索引擎(选区高亮 + 滚动定位),支持大小写/正则。
@MainActor
@Observable
final class TerminalSearchModel {
    var query = ""
    var caseSensitive = false
    var useRegex = false
    private(set) var matchIndex = 0
    private(set) var matchTotal = 0
    private(set) var searched = false

    weak var terminalView: TerminalView?

    var statusText: String {
        guard searched, !query.isEmpty else { return "" }
        if matchTotal == 0 { return String(localized: "无匹配") }
        return "\(matchIndex + 1) / \(matchTotal)"
    }

    private var options: SearchOptions {
        SearchOptions(caseSensitive: caseSensitive, regex: useRegex, wholeWord: false)
    }

    /// 查询/选项变化:重新从头搜索
    func update() {
        guard let terminalView else { return }
        terminalView.clearSearch()
        searched = false
        matchIndex = 0
        matchTotal = 0
        guard !query.isEmpty else { return }
        _ = terminalView.findNext(query, options: options)
        refreshSummary()
        searched = true
    }

    func next() {
        guard let terminalView, !query.isEmpty else { return }
        _ = terminalView.findNext(query, options: options)
        refreshSummary()
    }

    func previous() {
        guard let terminalView, !query.isEmpty else { return }
        _ = terminalView.findPrevious(query, options: options)
        refreshSummary()
    }

    func close() {
        terminalView?.clearSearch()
        query = ""
        searched = false
        matchIndex = 0
        matchTotal = 0
    }

    private func refreshSummary() {
        guard let terminalView else { return }
        let summary = terminalView.searchMatchSummary(query, options: options)
        matchIndex = max(summary.index - 1, 0)
        matchTotal = summary.total
    }
}

/// ⌘F 搜索条(覆盖在终端顶部)
struct TerminalSearchBar: View {
    @Bindable var model: TerminalSearchModel
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            PaletteTextField(
                text: $model.query,
                placeholder: String(localized: "在回滚缓冲中搜索"),
                onMoveUp: { model.previous() },
                onMoveDown: { model.next() },
                onSubmit: { model.next() },
                onCancel: { onClose() }
            )
            .frame(width: 200, height: 20)
            .onChange(of: model.query) { _, _ in model.update() }

            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .leading)

            Toggle("Aa", isOn: $model.caseSensitive)
                .toggleStyle(.button)
                .font(.caption)
                .help("区分大小写")
                .onChange(of: model.caseSensitive) { _, _ in model.update() }
            Toggle(".*", isOn: $model.useRegex)
                .toggleStyle(.button)
                .font(.caption.monospaced())
                .help("正则表达式")
                .onChange(of: model.useRegex) { _, _ in model.update() }

            Button {
                model.previous()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(model.matchTotal == 0)
            Button {
                model.next()
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(model.matchTotal == 0)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        )
        .padding(.top, 8)
    }
}
