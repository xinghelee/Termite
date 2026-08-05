import AppKit
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

    /// 搜索期间暂存的终端状态(关闭时还原)
    private var savedMouseReporting: Bool?
    private var savedSelectionColor: NSColor?

    /// 搜索打开时接管终端两处状态:
    /// 1. 关 allowMouseReporting——SwiftTerm 的 feedPrepare 在它开着时逢输出就清
    ///    选区,pane 里有 TUI 在刷屏(spinner/时钟)高亮设上即被抹掉;
    /// 2. 选区色换成「强调色对半调向背景」的高对比色——主题选区色贴着背景
    ///    (如默认 #2A3350),当搜索高亮几乎看不见。用实色不用 alpha,
    ///    CoreGraphics 与 Metal 两条渲染路径表现一致
    func activate() {
        guard let terminalView, savedMouseReporting == nil else { return }
        savedMouseReporting = terminalView.allowMouseReporting
        savedSelectionColor = terminalView.selectedTextBackgroundColor
        terminalView.allowMouseReporting = false
        let theme = ThemeStore.shared.current
        let accent = NSColor(hex: theme.accent)
        terminalView.selectedTextBackgroundColor =
            accent.blended(withFraction: 0.5, of: theme.backgroundNSColor) ?? accent
    }

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
        if let saved = savedMouseReporting { terminalView?.allowMouseReporting = saved }
        if let color = savedSelectionColor { terminalView?.selectedTextBackgroundColor = color }
        savedMouseReporting = nil
        savedSelectionColor = nil
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
