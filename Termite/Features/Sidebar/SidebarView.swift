import SwiftUI
import UniformTypeIdentifiers

/// 项目侧边栏:常用工作目录列表,点击即在该目录打开/切换终端标签。
/// 支持 + 按钮选文件夹、拖拽文件夹进列表、右键移除。
struct SidebarView: View {
    @Environment(SessionManager.self) private var sessionManager
    @State private var store = ProjectStore.shared
    @State private var workspaceStore = WorkspaceStore.shared
    @State private var spaceStore = SpaceStore.shared
    @State private var theme = ThemeStore.shared

    /// 当前工作区可见的项目:分组项目只在所属工作区,未分组全局可见
    private var visibleProjects: [Project] {
        store.projects.filter { spaceStore.isVisible($0) }
    }

    /// 首帧渲染后才启用工作区推入转场:冷启动恢复期窗口隐身(alpha 0),
    /// 初次插入若搭上动画事务,转场会冻在中间态——侧边栏半透明且点不中
    @State private var pushTransitionArmed = false

    var body: some View {
        VStack(spacing: 0) {
            // 切工作区:整列按切换方向水平推入(ZStack 让新旧列表过渡期间同位重叠)
            ZStack {
                projectList
                    .id(spaceStore.selected?.id)
                    .transition(pushTransitionArmed ? AnyTransition.push(from: spaceStore.slideEdge) : .identity)
            }
            .clipped()
            .onAppear {
                DispatchQueue.main.async { pushTransitionArmed = true }
            }
            spaceSwitcher
        }
        .background(theme.current.sidebarBackground)
        // 触控板在侧边栏上横扫切换工作区(Arc 手势)
        .background(SpaceSwipeCatcher())
        // 右缘发丝线:与标题栏下方的结构线呼应,划清侧边栏与终端区
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.current.borderColor)
                .frame(width: 1)
                .ignoresSafeArea()
        }
        // 侧边栏任意空白处右键即可新建/删除工作区(项目行/小点各有更近的菜单,不冲突)
        .contextMenu {
            Button("新建工作区…") { SpacePrompt.create() }
            if let space = spaceStore.selected {
                Divider()
                Button("删除工作区「\(space.name)」", role: .destructive) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        spaceStore.remove(space.id)
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            var paths: [String] = []
            for url in urls {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    paths.append(url.path)
                }
            }
            addAndOpen(paths)
            return !paths.isEmpty
        }
    }

    private var projectList: some View {
        List {
            Section {
                ForEach(visibleProjects) { project in
                    ProjectRow(
                        project: project,
                        isActive: isActive(project),
                        attention: SessionManagerRegistry.shared.attention(inProject: project.path),
                        open: { open(project) },
                        remove: { remove(project) }
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .onMove { from, to in
                    store.move(visibleIDs: visibleProjects.map(\.id), fromOffsets: from, toOffset: to)
                }
            } header: {
                HStack {
                    Text("项目")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.current.secondaryText)
                    Spacer()
                    HeaderIconButton(symbol: "plus", help: String(localized: "添加项目文件夹")) {
                        pickFolder()
                    }
                    .padding(.trailing, 4)
                }
            }

            if store.projects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("还没有项目")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("点「项目」旁的 + 选择文件夹,或把文件夹拖到这里。添加后直接进入该目录,之后点一下即可切换。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .padding(.top, 2)
            }
            // 新工作区没有内容时保持空白(Arc 惯例):不塞引导文案

            if WorkspaceStore.isEnabled {
                workspaceSection
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    /// Arc 式工作区切换器:底部一排小圆点(选中=专属色实心并放大),
    /// 点击 / 触控板横扫 / ⌃⌥←→ 切换,右键新建与管理;没有工作区时不出现
    @ViewBuilder private var spaceSwitcher: some View {
        if !spaceStore.spaces.isEmpty {
            VStack(spacing: 4) {
                // 当前工作区名:小点上方居中,随切换同方向推入;双击改名
                if let space = spaceStore.selected {
                    ZStack {
                        Text(space.name)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .id(space.id)
                            .transition(.push(from: spaceStore.slideEdge))
                    }
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { SpacePrompt.rename(space) }
                    .help(String(localized: "双击重命名"))
                }
                HStack(spacing: 9) {
                    Spacer(minLength: 0)
                    ForEach(spaceStore.spaces) { space in
                        SpaceDot(
                            space: space,
                            isSelected: space.id == spaceStore.selected?.id,
                            hasAttention: spaceAttention(space),
                            select: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    spaceStore.select(space.id)
                                }
                            },
                            remove: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    spaceStore.remove(space.id)
                                }
                            }
                        )
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.top, 5)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .help(String(localized: "点击 / 触控板横扫 / ⌃⌥←→ 切换工作区"))
        }
    }

    /// 工作区聚合注意力:组内任一项目有分屏等待输入,小点转橙色
    private func spaceAttention(_ space: SidebarSpace) -> Bool {
        store.projects.contains {
            $0.spaceID == space.id &&
                SessionManagerRegistry.shared.attention(inProject: $0.path) == .needsInput
        }
    }

    /// 工作区区块(恢复布局 bug 修复前由 WorkspaceStore.isEnabled 隐藏)
    private var workspaceSection: some View {
        Section {
            ForEach(workspaceStore.workspaces) { workspace in
                WorkspaceRow(
                    workspace: workspace,
                    open: { sessionManager.openWorkspace(workspace) },
                    overwrite: { workspaceStore.overwrite(workspace, tabs: sessionManager.captureWorkspaceTabs()) },
                    remove: { workspaceStore.remove(workspace) }
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            if workspaceStore.workspaces.isEmpty {
                Text("把当前「标签 + 分屏」整套布局存成模板,一键恢复。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        } header: {
            HStack {
                Text("工作区")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.current.secondaryText)
                Spacer()
                HeaderIconButton(symbol: "plus.square.on.square", help: String(localized: "保存当前布局为工作区模板")) {
                    saveCurrentLayout()
                }
                .disabled(sessionManager.tabs.isEmpty)
                .padding(.trailing, 4)
            }
        }
    }

    /// 当前标签绑定了项目就认绑定(cd 走了也照样点亮);没绑定则看聚焦会话的 cwd 是否落在项目里
    private func isActive(_ project: Project) -> Bool {
        if let bound = sessionManager.selectedTab?.projectPath {
            return bound == project.path
        }
        guard let cwd = sessionManager.selected?.workingDirectory else { return false }
        return cwd == project.path || cwd.hasPrefix(project.path + "/")
    }

    private func open(_ project: Project) {
        sessionManager.openProject(path: project.path)
    }

    /// 添加项目(+ 或拖入)后立即切到它的工作目录:最后一个成为当前标签
    private func addAndOpen(_ paths: [String]) {
        for path in paths {
            store.add(path: path)
        }
        if let last = paths.last {
            sessionManager.openProject(path: (last as NSString).standardizingPath)
        }
    }

    /// 从侧边栏移除项目:绑定它的标签(所有窗口)一起关掉,标签栏不留孤儿
    private func remove(_ project: Project) {
        let running = SessionManagerRegistry.shared.runningCommandCount(inProject: project.path)
        let needsConfirm = UserDefaults.standard.object(forKey: SettingsKeys.confirmBeforeClosingTab) as? Bool ?? true
        if running > 0, needsConfirm {
            let alert = NSAlert()
            alert.messageText = String(localized: "移除「\(project.name)」并关闭它的标签?")
            alert.informativeText = String(localized: "该项目的标签里还有 \(running) 个命令在运行,关闭会终止它们。")
            alert.addButton(withTitle: String(localized: "移除并关闭"))
            alert.addButton(withTitle: String(localized: "取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        SessionManagerRegistry.shared.closeProjectTabs(path: project.path)
        store.remove(project)
    }

    /// 保存当前布局:弹一个带输入框的确认框取名
    private func saveCurrentLayout() {
        let alert = NSAlert()
        alert.messageText = String(localized: "保存当前布局为工作区")
        alert.informativeText = String(localized: "包含所有标签的分屏结构、比例与各 pane 的工作目录。")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = String(localized: "工作区名称")
        field.stringValue = sessionManager.selected?.displayTitle ?? String(localized: "布局 \(workspaceStore.workspaces.count + 1)")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "保存"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        workspaceStore.add(
            name: name.isEmpty ? String(localized: "未命名布局") : name,
            tabs: sessionManager.captureWorkspaceTabs()
        )
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.message = String(localized: "选择要固定到侧边栏的项目文件夹(左下角可新建)")
        if panel.runModal() == .OK {
            addAndOpen(panel.urls.map(\.path))
        }
    }
}

/// 侧边栏区块标题右侧的图标按钮。iOS 导航栏加号的质感:强调色描线、
/// 24pt 圆形触控区、悬停浮出一层同色淡底、按下回弹一下。
private struct HeaderIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false
    @State private var theme = ThemeStore.shared

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(theme.current.accentColor.opacity(hovering ? 1 : 0.85))
                .frame(width: 24, height: 24)
                .background(Circle().fill(theme.current.accentColor.opacity(hovering ? 0.16 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(SpringyIconButtonStyle())
        .animation(.easeOut(duration: 0.14), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 按下缩一下再弹回来:iOS 控件的手感,弹簧参数取「快而不飘」
private struct SpringyIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace
    let open: () -> Void
    let overwrite: () -> Void
    let remove: () -> Void

    @State private var hovering = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1.5) {
                Text(workspace.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("\(workspace.tabs.count) 标签 · \(workspace.paneCount) pane")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            Button("打开(追加标签)") { open() }
            Button("用当前布局覆盖") { overwrite() }
            Divider()
            Button("删除", role: .destructive, action: remove)
        }
    }
}

/// 工作区小圆点(Arc 底部指示器):单色——选中=亮点并放大,未选中=暗点、
/// 悬停提亮;组内有分屏等待输入且未选中时转橙色。右键新建与管理
private struct SpaceDot: View {
    let space: SidebarSpace
    let isSelected: Bool
    var hasAttention = false
    let select: () -> Void
    let remove: () -> Void

    @State private var hovering = false

    private var fill: Color {
        if isSelected { return Color.primary.opacity(0.9) }
        if hasAttention { return .orange }
        return Color.primary.opacity(hovering ? 0.5 : 0.22)
    }

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: isSelected ? 8 : 6, height: isSelected ? 8 : 6)
            .scaleEffect(hovering && !isSelected ? 1.25 : 1)
            // 点太小不好点:外扩一圈隐形命中区
            .frame(width: 16, height: 16)
            .contentShape(Circle())
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .onTapGesture(perform: select)
            .contextMenu {
                Button("重命名") { SpacePrompt.rename(space) }
                Button("新建工作区…") { SpacePrompt.create() }
                Divider()
                Button("删除工作区(项目归入第一个工作区)", role: .destructive) { remove() }
            }
            .help(space.name)
    }
}

/// 工作区取名弹框:新建 / 重命名共用(菜单栏、右键多处入口)
@MainActor
enum SpacePrompt {
    /// 弹框输入框:单行模式——多行 cell 会把文字顶到上缘且长占位换行,
    /// 单行才垂直居中、超长滚动
    private static func nameField() -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        return field
    }

    @discardableResult
    static func create() -> SidebarSpace? {
        let alert = NSAlert()
        alert.messageText = String(localized: "新建工作区")
        alert.informativeText = String(localized: "分组项目只在所属工作区显示;新工作区从空白开始,现有项目归入第一个工作区。")
        let field = nameField()
        field.placeholderString = String(localized: "工作区名称,如:工作 / 个人")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "创建"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var created: SidebarSpace?
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            created = SpaceStore.shared.add(name: name)
        }
        return created
    }

    static func rename(_ space: SidebarSpace) {
        let alert = NSAlert()
        alert.messageText = String(localized: "重命名工作区")
        let field = nameField()
        field.stringValue = space.name
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "确定"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        SpaceStore.shared.rename(space.id, to: name)
    }
}

/// 触控板横扫切换工作区(Arc 手势):本地监视器捕获落在侧边栏上的横向滚动,
/// 按手势主导轴判定、一次手势只切一档;纵向滚动(项目列表)不受影响
private struct SpaceSwipeCatcher: NSViewRepresentable {
    final class CatcherView: NSView {
        private var monitor: Any?
        private var accum: CGFloat = 0
        private var fired = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    MainActor.assumeIsolated { self?.route(event) ?? event }
                }
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func route(_ event: NSEvent) -> NSEvent? {
            guard event.window === window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return event }
            if event.phase == .began {
                accum = 0
                fired = false
            }
            // 惯性阶段不计入,避免一次横扫连跳多档
            guard event.momentumPhase == [], abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
                return event
            }
            accum += event.scrollingDeltaX
            if !fired, abs(accum) > 50 {
                fired = true
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    // 自然滚动:指尖右扫(deltaX 正)= 上一个,左扫 = 下一个
                    SpaceStore.shared.selectAdjacent(accum > 0 ? -1 : 1)
                }
            }
            return nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ nsView: CatcherView, context: Context) {}
}

private struct ProjectRow: View {
    let project: Project
    let isActive: Bool
    var attention: SessionManagerRegistry.ProjectAttention = .none
    let open: () -> Void
    let remove: () -> Void

    @State private var hovering = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    /// 项目专属色:设置后文件夹图标常年带色(Finder 标签的认知),未设置跟随主题
    private var projectColor: Color? {
        project.accentHex.map { Color(nsColor: NSColor(hex: $0)) }
    }

    private var rowAccent: Color { projectColor ?? theme.accentColor }

    var body: some View {
        HStack(spacing: 8) {
            // Finder 式裸图标:固定宽度对齐成列,活动态用强调色
            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(projectColor?.opacity(isActive ? 1 : 0.8) ?? (isActive ? theme.accentColor : Color.secondary))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1.5) {
                Text(project.name)
                    .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                    .lineLimit(1)
                Text((project.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            // 注意力提醒点盖过活动态点:等待输入橙点 > 命令完成强调色点 > 当前项目点
            if attention == .needsInput {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .help("该项目有分屏在等待输入(⌘J 跳转)")
            } else if attention == .finished {
                Circle()
                    .fill(rowAccent)
                    .frame(width: 6, height: 6)
                    .help("该项目有命令已完成")
            } else if isActive {
                Circle()
                    .fill(rowAccent)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(isActive ? rowAccent.opacity(0.16) : (hovering ? Color.primary.opacity(0.06) : .clear))
        )
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            Button("切换到该项目") { open() }
            Button("在 Finder 中打开") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
            }
            Divider()
            Menu("移动到工作区") {
                ForEach(SpaceStore.shared.spaces) { space in
                    Toggle(isOn: Binding(
                        get: { SpaceStore.shared.effectiveSpaceID(of: project) == space.id },
                        set: { on in if on { ProjectStore.shared.setSpace(space.id, for: project.id) } }
                    )) {
                        Text(space.name)
                    }
                }
                if !SpaceStore.shared.spaces.isEmpty {
                    Divider()
                }
                Button("新建工作区…") {
                    if let space = SpacePrompt.create() {
                        ProjectStore.shared.setSpace(space.id, for: project.id)
                    }
                }
            }
            Menu("项目颜色") {
                ForEach(ProjectAccentPreset.all) { preset in
                    Toggle(isOn: Binding(
                        get: { project.accentHex == preset.hex },
                        set: { on in ProjectStore.shared.setAccent(on ? preset.hex : nil, for: project.id) }
                    )) {
                        Label { Text(preset.name) } icon: { Image(nsImage: preset.swatchImage) }
                    }
                }
                Divider()
                Button("跟随主题") { ProjectStore.shared.setAccent(nil, for: project.id) }
            }
            Divider()
            Button("移除(并关闭其标签)", role: .destructive, action: remove)
        }
        .help(project.path)
    }
}
