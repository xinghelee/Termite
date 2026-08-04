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

    var body: some View {
        VStack(spacing: 0) {
            spacePager
            spaceSwitcher
        }
        // chrome 带:与标题栏同色,并越过安全区一路铺到窗口顶,左上角不留色阶断层
        .background(theme.current.sidebarBackground.ignoresSafeArea())
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
            SidebarActions.addAndOpen(paths, in: sessionManager)
            return !paths.isEmpty
        }
    }

    /// 工作区切换的 shared-axis 转场:当前页与相邻页同位叠放,一起做
    /// 「小位移 + 交叉淡入」——内容只走 36pt,交接靠透明度完成。
    /// 相邻页常驻(透明度 0),手势途中不构建任何新页面,所以没有中途卡顿
    @ViewBuilder private var spacePager: some View {
        if spaceStore.spaces.count > 1 {
            GeometryReader { geo in
                let progress = spaceStore.dragProgress
                let index = spaceStore.selectedIndex
                ZStack {
                    if index > 0 {
                        page(at: index - 1).modifier(SharedAxisSlide(progress: progress - 1))
                    }
                    if index < spaceStore.spaces.count - 1 {
                        page(at: index + 1).modifier(SharedAxisSlide(progress: progress + 1))
                    }
                    page(at: index).modifier(SharedAxisSlide(progress: progress))
                }
            }
            .clipped()
        } else {
            page(at: 0)
        }
    }

    private func page(at index: Int) -> some View {
        let space = spaceStore.spaces.indices.contains(index) ? spaceStore.spaces[index] : nil
        return ProjectListPage(
            projects: projects(in: space),
            showsGuide: store.projects.isEmpty
        )
    }

    /// 指定工作区里的项目;没有工作区时是全量扁平列表
    private func projects(in space: SidebarSpace?) -> [Project] {
        guard let space else { return store.projects }
        return store.projects.filter { spaceStore.effectiveSpaceID(of: $0) == space.id }
    }

    /// Arc 式工作区切换器:底部一排小圆点(选中=专属色实心并放大),
    /// 点击 / 触控板横扫 / ⌃⌥←→ 切换,右键新建与管理;没有工作区时不出现
    @ViewBuilder private var spaceSwitcher: some View {
        if !spaceStore.spaces.isEmpty {
            VStack(spacing: 4) {
                // 当前工作区名:小点上方居中,随切换同方向推入;双击改名。
                // 跟手拖拽时同步淡出并轻微跟随,松手落定后新名字推入
                if let space = spaceStore.selected {
                    ZStack {
                        Text(space.name)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .id(space.id)
                            .transition(.push(from: spaceStore.slideEdge))
                    }
                    .opacity(1 - nameFade * 0.8)
                    .offset(x: spaceStore.dragProgress * 10)
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

    /// 工作区名淡出的驱动量:0…1
    private var nameFade: CGFloat {
        min(1, abs(spaceStore.dragProgress))
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
                PanelIconButton(symbol: "plus.square.on.square", help: String(localized: "保存当前布局为工作区模板")) {
                    saveCurrentLayout()
                }
                .disabled(sessionManager.tabs.isEmpty)
                .padding(.trailing, 2)
            }
        }
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

}

/// shared-axis 转场的单页姿态。progress 0 = 正位且不透明;±1 = 让到一侧并完全透明。
/// 位移只有 36pt——「轻盈」来自小位移 + 透明度交接,不是来自把整个列表推过整屏
private struct SharedAxisSlide: ViewModifier {
    let progress: CGFloat

    private var clamped: CGFloat { max(-1, min(1, progress)) }

    func body(content: Content) -> some View {
        content
            .offset(x: clamped * 36)
            .opacity(Double(1 - abs(clamped)))
            // 让出去的一页同时收一点,避免纯平移的呆板
            .scaleEffect(1 - abs(clamped) * 0.02, anchor: .center)
            // 透明的页不该还能点
            .allowsHitTesting(abs(clamped) < 0.5)
    }
}

/// 单个工作区的项目列表。**刻意不用 `List`**:侧边栏把 List 的分隔线、行背景、
/// 滚动背景全关了,自己画胶囊,等于付了 NSTableView 的代价却一样没用上;
/// 而转场里每帧重算一个 NSTableView 正是卡顿的来源。ScrollView + LazyVStack
/// 又轻又完全可控。入参是 Equatable 的,手势途中 SwiftUI 会整页跳过重算
private struct ProjectListPage: View {
    let projects: [Project]
    let showsGuide: Bool

    @Environment(SessionManager.self) private var sessionManager
    @State private var theme = ThemeStore.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                header
                ForEach(projects) { project in
                    ProjectRow(
                        project: project,
                        isActive: isActive(project),
                        attention: SessionManagerRegistry.shared.attention(inProject: project.path),
                        open: { sessionManager.openProject(path: project.path) },
                        remove: { remove(project) }
                    )
                }
                if showsGuide { guide }
                // 新工作区没有内容时保持空白(Arc 惯例):不塞引导文案
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .scrollContentBackground(.hidden)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("项目")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.current.secondaryText)
            Spacer(minLength: 0)
            PanelIconButton(symbol: "plus", help: String(localized: "添加项目文件夹")) {
                pickFolder()
            }
        }
        .padding(.leading, 8)
        .padding(.bottom, 2)
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还没有项目")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("点「项目」旁的 + 选择文件夹,或把文件夹拖到这里。添加后直接进入该目录,之后点一下即可切换。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }

    /// 当前标签绑定了项目就认绑定(cd 走了也照样点亮);没绑定则看聚焦会话的 cwd 是否落在项目里
    private func isActive(_ project: Project) -> Bool {
        if let bound = sessionManager.selectedTab?.projectPath {
            return bound == project.path
        }
        guard let cwd = sessionManager.selected?.workingDirectory else { return false }
        return cwd == project.path || cwd.hasPrefix(project.path + "/")
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.message = String(localized: "选择要固定到侧边栏的项目文件夹(左下角可新建)")
        if panel.runModal() == .OK {
            SidebarActions.addAndOpen(panel.urls.map(\.path), in: sessionManager)
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
        ProjectStore.shared.remove(project)
    }
}

/// 侧边栏的公共动作(+ 按钮与拖入文件夹共用)
@MainActor
enum SidebarActions {
    /// 添加项目后立即切到它的工作目录:最后一个成为当前标签
    static func addAndOpen(_ paths: [String], in manager: SessionManager) {
        for path in paths {
            ProjectStore.shared.add(path: path)
        }
        if let last = paths.last {
            manager.openProject(path: (last as NSString).standardizingPath)
        }
    }
}

/// 项目行拖拽重排的载荷:走私有 JSON 类型,与 Finder 文件拖拽的公共类型互不相认
struct ProjectDragPayload: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

/// 项目行的集合。单独抽出来是为了跟手横扫:拖拽期间 dragOffset 每帧变,
/// SidebarView 的 body 跟着重算;这一层的入参(项目数组)没变时 SwiftUI
/// 会跳过它的 body,列表不会每帧重建
private struct ProjectRows: View {
    let projects: [Project]

    @Environment(SessionManager.self) private var sessionManager

    var body: some View {
        ForEach(projects) { project in
            ProjectRow(
                project: project,
                isActive: isActive(project),
                attention: SessionManagerRegistry.shared.attention(inProject: project.path),
                open: { sessionManager.openProject(path: project.path) },
                remove: { remove(project) }
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
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
        ProjectStore.shared.remove(project)
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
/// 把累计位移实时喂给 SpaceStore —— 画面严格跟着手指走,松手才判定换档还是弹回。
/// 轴锁定在手势开头一次性判定并锁死整段,纵向滚动(项目列表)不受影响
private struct SpaceSwipeCatcher: NSViewRepresentable {
    final class CatcherView: NSView {
        private var monitor: Any?
        /// 本次手势的横向累计位移与纵向累计位移(纵向只用于轴判定)
        private var accumX: CGFloat = 0
        private var accumY: CGFloat = 0
        /// 已锁定为横扫:锁定后整段手势都归工作区切换,不再改判
        private var tracking = false
        /// 已接管过本次手势:随后的惯性事件一并吞掉,免得漏进列表里滚一下
        private var swallowsMomentum = false
        /// 平滑后的横向速度,单位 pt/s(松手时喂给弹簧当初速度,惯性感来自它)
        private var velocityX: CGFloat = 0
        /// 上一记事件的时间戳:速度要按真实间隔算,不能假设 60Hz
        private var lastTimestamp: TimeInterval = 0
        /// 收尾看门狗:纯兜底,见 scheduleSettle
        private var settleTimer: Timer?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
                settleTimer?.invalidate()
                settleTimer = nil
                if tracking {
                    tracking = false
                    SpaceStore.shared.dragCancelled()
                }
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
            // 收尾事件抢在窗口归属校验之前处理:抬手那一记 ended 未必带着我们这个
            // 窗口(指针飘出窗口、事件被合成时都可能为空),一旦被 window 校验挡掉,
            // 手势就永远收不了尾,strip 卡死在两个工作区之间。只要正在跟手,
            // 任何来源的 ended/cancelled 都算松手
            if tracking, event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                finishGesture()
                return nil
            }
            guard event.window === window else { return event }

            if event.momentumPhase != [] {
                // 手指已离开,换档与否在松手那一刻就定了;惯性不再推进位移
                return swallowsMomentum ? nil : event
            }
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                // 上一次手势要是没收尾(收尾事件丢了),在这里补一记,绝不带着残留进度开新手势
                finishGesture()
                accumX = 0
                accumY = 0
                velocityX = 0
                lastTimestamp = event.timestamp
                swallowsMomentum = false
                return event
            }
            // 手指按在触控板上不动时系统会发 stationary:这不是松手,
            // 只是把看门狗的计时推后,免得停顿被误判成松手(那就是「停顿卡一下」)
            if event.phase.contains(.stationary) {
                if tracking {
                    velocityX = 0
                    lastTimestamp = event.timestamp
                    scheduleSettle()
                    return nil
                }
                return event
            }
            if event.phase.contains(.changed) {
                accumX += event.scrollingDeltaX
                accumY += event.scrollingDeltaY
                if !tracking {
                    guard shouldLockHorizontal(event) else { return event }
                    swallowsMomentum = true
                    tracking = true
                }
                updateVelocity(event)
                // 自然滚动:指尖右扫(deltaX 正)= 内容右移,上一个工作区从左侧进
                SpaceStore.shared.dragChanged(accumX, width: bounds.width)
                scheduleSettle()
                return nil
            }
            return event
        }

        /// 速度按真实事件间隔算成 pt/s 再平滑。只累加每帧 delta 得到的是
        /// 「每帧位移」,和刷新率绑死,喂给弹簧当初速度会离谱
        private func updateVelocity(_ event: NSEvent) {
            let dt = event.timestamp - lastTimestamp
            lastTimestamp = event.timestamp
            guard dt > 0.0001, dt < 0.1 else { return }
            let instant = event.scrollingDeltaX / CGFloat(dt)
            velocityX = velocityX * 0.5 + instant * 0.5
        }

        /// 手势收尾的唯一出口:结束事件与看门狗都走这里,保证只吸附一次
        private func finishGesture() {
            settleTimer?.invalidate()
            settleTimer = nil
            guard tracking else { return }
            tracking = false
            SpaceStore.shared.dragEnded(velocity: velocityX, width: bounds.width)
        }

        /// 收尾看门狗:纯兜底。正常松手由 ended 立刻收尾,停顿有 stationary 续命,
        /// 轮不到它;留着只是因为「停在两个工作区中间」是死也不能出现的状态,
        /// 而结束事件的 phase 语义并非所有输入设备都一致。
        /// 常规 run loop 模式下拖拽/菜单会挂起定时器,必须用 .common
        private func scheduleSettle() {
            settleTimer?.invalidate()
            let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishGesture() }
            }
            RunLoop.main.add(timer, forMode: .common)
            settleTimer = timer
        }

        /// 轴锁定:指针在侧边栏内、有多个工作区、且手势起步阶段横向明显压过纵向。
        /// 只在纵向还没走远时判定——列表滚到一半的横向抖动不该被当成切换
        private func shouldLockHorizontal(_ event: NSEvent) -> Bool {
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point),
                  SpaceStore.shared.spaces.count > 1,
                  abs(accumY) < 12,
                  abs(event.scrollingDeltaX) > 0.5,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5 else { return false }
            return true
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            settleTimer?.invalidate()
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

    @Environment(SessionManager.self) private var sessionManager
    @State private var hovering = false
    @State private var isRenaming = false
    @State private var editText = ""
    @FocusState private var renameFocused: Bool

    private var theme: TerminalTheme { ThemeStore.shared.current }

    /// 项目专属色:设置后文件夹图标常年带色(Finder 标签的认知),未设置跟随主题
    private var projectColor: Color? {
        project.accentHex.map { Color(nsColor: NSColor(hex: $0)) }
    }

    private var rowAccent: Color { projectColor ?? theme.accentColor }

    private func commitRename() {
        guard isRenaming else { return }
        ProjectStore.shared.rename(project.id, to: editText)
        isRenaming = false
        // 输入框收起后把键盘交还终端:推迟一拍,否则 AppKit 会在它移出视图树时
        // 再分配一次 first responder,把这次抢回来(与标签改名同一处理)
        let manager = sessionManager
        DispatchQueue.main.async { manager.selected?.focusTerminal() }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Finder 式裸图标:固定宽度对齐成列,活动态用强调色
            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(projectColor?.opacity(isActive ? 1 : 0.8) ?? (isActive ? theme.accentColor : Color.secondary))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1.5) {
                if isRenaming {
                    TextField("", text: $editText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .focused($renameFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand {
                            // Esc 放弃修改
                            isRenaming = false
                            let manager = sessionManager
                            DispatchQueue.main.async { manager.selected?.focusTerminal() }
                        }
                        .onAppear {
                            editText = project.name
                            renameFocused = true
                        }
                        .onChange(of: renameFocused) { _, focused in
                            if !focused { commitRename() } // 点别处失焦即提交
                        }
                } else {
                    Text(project.name)
                        .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                        .lineLimit(1)
                }
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
        // 选中态与标题栏的选中标签同一块材质(浮起 + 顶部高光),
        // 强调色只留在文件夹图标与状态点上——全窗「选中 = 浮起」是一条规则
        .background {
            if isActive {
                RaisedCapsule()
            } else if hovering {
                Capsule().fill(Color.primary.opacity(0.06))
            }
        }
        .foregroundStyle(isActive ? .primary : .secondary)
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        // 双击改名(先注册,优先于单击打开;首击仍会切过去,正好选中被改名的项目)
        .onTapGesture(count: 2) {
            guard !isRenaming else { return }
            isRenaming = true
        }
        .onTapGesture {
            guard !isRenaming else { return }
            open()
        }
        // 拖拽重排:拖起一行丢到另一行上,占据其位置(与标签 chip 同一手感)。
        // 载荷用私有 JSON 类型而不是字符串——Finder 拖文件夹时会一并提供纯文本,
        // 行上若挂着字符串 drop 目标就会把「拖文件夹进侧边栏」半路截胡
        .draggable(ProjectDragPayload(id: project.id))
        .dropDestination(for: ProjectDragPayload.self) { items, _ in
            guard let dragged = items.first?.id else { return false }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                ProjectStore.shared.move(dragged, before: project.id)
            }
            return true
        }
        .contextMenu {
            Button("切换到该项目") { open() }
            Button("重命名") { isRenaming = true }
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
        // 路径下面挂一行手势提示:改名与排序都没有常驻按钮,靠 tooltip 让人知道有这回事
        .help(project.path + "\n" + String(localized: "双击重命名 · 拖动调整顺序"))
    }
}
