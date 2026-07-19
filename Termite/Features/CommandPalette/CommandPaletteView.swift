import SwiftUI

/// ⌘P 全局命令面板:模糊搜索「终端动作」+「主题切换」,回车执行。
struct CommandPaletteView: View {
    @Environment(SessionManager.self) private var sessionManager

    @State private var query = ""
    @State private var selectionIndex = 0
    @State private var themeStore = ThemeStore.shared

    /// 本窗口的面板控制器(多窗口下各自独立)
    private var controller: CommandPaletteController { sessionManager.palette }

    // MARK: - 命令清单

    private var commands: [PaletteCommand] {
        let m = sessionManager
        let hasSession = m.selected != nil
        var list: [PaletteCommand] = [
            PaletteCommand(id: "new-tab", title: String(localized: "新建标签页"), subtitle: "⌘T", icon: "plus.square") {
                m.newTab()
            },
            PaletteCommand(id: "split-h", title: String(localized: "左右分屏"), subtitle: "⌘D", icon: "rectangle.split.2x1", isEnabled: hasSession) {
                m.splitFocused(axis: .horizontal)
            },
            PaletteCommand(id: "split-v", title: String(localized: "上下分屏"), subtitle: "⌘⇧D", icon: "rectangle.split.1x2", isEnabled: hasSession) {
                m.splitFocused(axis: .vertical)
            },
            PaletteCommand(id: "close-pane", title: String(localized: "关闭当前分屏"), subtitle: "⌘W", icon: "xmark.rectangle", isEnabled: hasSession) {
                m.requestCloseCurrent()
            },
            PaletteCommand(
                id: "broadcast",
                title: m.isBroadcasting ? String(localized: "停止广播输入") : String(localized: "广播输入到所有分屏"),
                subtitle: "⌘⌥B",
                icon: "dot.radiowaves.left.and.right",
                isEnabled: (m.selectedTab?.root.leafIDs().count ?? 0) > 1
            ) {
                m.toggleBroadcast()
            },
            PaletteCommand(id: "find", title: String(localized: "在终端中查找"), subtitle: "⌘F", icon: "magnifyingglass", isEnabled: hasSession) {
                m.requestSearch()
            },
            PaletteCommand(
                id: "timeline",
                title: m.isTimelineVisible ? String(localized: "关闭命令时间线") : String(localized: "打开命令时间线"),
                subtitle: "⌘I",
                icon: "clock.arrow.circlepath",
                isEnabled: hasSession
            ) {
                m.toggleTimeline()
            },
            PaletteCommand(
                id: "git-panel",
                title: m.isGitPanelVisible ? String(localized: "关闭 Git 面板") : String(localized: "打开 Git 面板"),
                subtitle: "⌘G",
                icon: "arrow.trianglehead.branch",
                isEnabled: hasSession
            ) {
                m.toggleGitPanel()
            },
            PaletteCommand(
                id: "file-browser",
                title: m.isFileBrowserVisible ? String(localized: "关闭文件浏览器") : String(localized: "打开文件浏览器"),
                subtitle: "⌘⇧E",
                icon: "folder",
                isEnabled: hasSession
            ) {
                m.toggleFileBrowser()
            },
            PaletteCommand(id: "clear", title: String(localized: "清空回滚缓冲"), subtitle: "⌘K", icon: "eraser", isEnabled: hasSession) {
                m.selected?.clearBuffer()
            },
            PaletteCommand(id: "copy-output", title: String(localized: "复制上条命令输出"), subtitle: "⌘⇧C", icon: "text.viewfinder", isEnabled: m.selected?.hasCommandOutput ?? false) {
                m.selected?.copyLastCommandOutput()
            },
            PaletteCommand(
                id: "log",
                title: m.selected?.isLogging == true ? String(localized: "停止记录会话") : String(localized: "记录会话到文件…"),
                icon: "record.circle",
                isEnabled: hasSession
            ) {
                m.toggleSessionLogging()
            },
            PaletteCommand(id: "history-search", title: String(localized: "搜索命令历史(跨会话)"), subtitle: "⌘⇧H", icon: "clock.arrow.circlepath") {
                m.historySearch.toggle()
            },
            PaletteCommand(id: "daily-report", title: String(localized: "生成今日工作日报"), icon: "doc.text") {
                m.dailyReportPresented = true
            },
            PaletteCommand(id: "ports", title: String(localized: "端口管理(谁占了 3000)"), icon: "network") {
                m.portsPresented = true
            },
            PaletteCommand(id: "quick-terminal", title: String(localized: "下拉终端"), subtitle: QuickTerminalHotkey.current.label, icon: "rectangle.topthird.inset.filled") {
                QuickTerminalController.shared.toggle()
            },
            PaletteCommand(id: "reveal-cwd", title: String(localized: "在 Finder 中打开工作目录"), icon: "folder", isEnabled: m.selected?.workingDirectory != nil) {
                if let dir = m.selected?.workingDirectory {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
                }
            },
        ]
        // 工作区模板一键恢复(入口随 WorkspaceStore.isEnabled 隐藏)
        for workspace in WorkspaceStore.shared.workspaces where WorkspaceStore.isEnabled {
            list.append(PaletteCommand(
                id: "workspace." + workspace.id.uuidString,
                title: String(localized: "工作区:\(workspace.name)"),
                subtitle: String(localized: "\(workspace.tabs.count) 标签"),
                icon: "square.grid.2x2"
            ) {
                m.openWorkspace(workspace)
            })
        }
        // 项目快速切换(与侧边栏同源)
        for project in ProjectStore.shared.projects {
            list.append(PaletteCommand(
                id: "project." + project.id.uuidString,
                title: String(localized: "项目:\(project.name)"),
                subtitle: (project.path as NSString).abbreviatingWithTildeInPath,
                icon: "folder"
            ) {
                m.openProject(path: project.path)
            })
        }
        // 主题切换命令
        for theme in TerminalTheme.builtIn {
            list.append(PaletteCommand(
                id: "theme." + theme.id,
                title: String(localized: "主题:\(theme.name)"),
                subtitle: themeStore.current.id == theme.id ? String(localized: "当前") : nil,
                icon: "paintpalette"
            ) {
                themeStore.select(id: theme.id)
            })
        }
        return list
    }

    private var rows: [PaletteCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return Array(commands.prefix(9))
        }
        let scored: [(PaletteCommand, Int)] = commands.compactMap { c in
            guard let s = FuzzyMatcher.bestScore(query: trimmed, fields: [c.title, c.subtitle]) else { return nil }
            return (c, s)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(12).map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                PaletteTextField(
                    text: $query,
                    placeholder: String(localized: "搜索命令或主题…"),
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
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, command in
                                rowView(command, isSelected: index == selectionIndex)
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
    private func rowView(_ command: PaletteCommand, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.icon)
                .frame(width: 18)
                .foregroundStyle(command.isEnabled ? .primary : .tertiary)
            Text(command.title)
                .foregroundStyle(command.isEnabled ? .primary : .tertiary)
            Spacer()
            if let sub = command.subtitle {
                Text(sub).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }

    private func activate() {
        guard rows.indices.contains(selectionIndex) else { return }
        let command = rows[selectionIndex]
        guard command.isEnabled else { return }
        controller.dismiss()
        command.run()
    }
}
