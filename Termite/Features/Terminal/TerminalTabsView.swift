import SwiftUI

/// 终端区:标签 chips(标题栏)+ 当前标签的分屏树 + 底部状态栏
struct TerminalTabsView: View {
    /// 侧边栏切换(系统按钮已移除,由这里统一样式渲染);nil 时不显示
    var toggleSidebar: (() -> Void)? = nil

    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.openWindow) private var openWindow
    @State private var chipsContentWidth: CGFloat = 0
    @State private var chipsContainerWidth: CGFloat = 0

    var body: some View {
        @Bindable var manager = sessionManager
        VStack(spacing: 0) {
            // 标题栏与终端区同色,一条发丝线划出结构边界
            Rectangle()
                .fill(ThemeStore.shared.current.borderColor)
                .frame(height: 1)
            if sessionManager.tabs.isEmpty {
                emptyState
            } else if let tab = sessionManager.selectedTab {
                if tab.isBroadcasting {
                    broadcastBanner
                }
                HStack(spacing: 0) {
                    if let maximizedID = tab.maximizedID,
                       let maximized = sessionManager.session(maximizedID) {
                        // ⇧⌘↩ 最大化:只渲染该 pane,右上角挂还原提示
                        TerminalPaneView(session: maximized)
                            .id(maximizedID)
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    sessionManager.toggleMaximizePane()
                                } label: {
                                    Label("已最大化 · ⇧⌘↩ 还原", systemImage: "arrow.down.right.and.arrow.up.left")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(.regularMaterial))
                                }
                                .buttonStyle(.plain)
                                .padding(10)
                            }
                    } else {
                    PaneTreeView(
                        node: tab.root,
                        focusedID: tab.focusedID,
                        showsFocus: tab.root.leafIDs().count > 1,
                        broadcasting: tab.isBroadcasting,
                        onFocus: { id in
                            sessionManager.focusPane(id)
                        },
                        onResize: { branchID, ratio in
                            tab.root = tab.root.settingRatio(branch: branchID, ratio: ratio)
                        }
                    )
                    }
                    if sessionManager.isTimelineVisible, let session = sessionManager.selected {
                        Divider().overlay(ThemeStore.shared.current.borderColor)
                        CommandTimelineView(session: session) {
                            sessionManager.isTimelineVisible = false
                        }
                        .id(session.id)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    if sessionManager.isGitPanelVisible, let session = sessionManager.selected {
                        Divider().overlay(ThemeStore.shared.current.borderColor)
                        GitPanelView(session: session) {
                            sessionManager.isGitPanelVisible = false
                        }
                        .id(session.id)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    if sessionManager.isFileBrowserVisible, let session = sessionManager.selected {
                        Divider().overlay(ThemeStore.shared.current.borderColor)
                        FileBrowserView(session: session) {
                            sessionManager.isFileBrowserVisible = false
                        }
                        .id(session.id)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                if let session = sessionManager.selected {
                    StatusBarView(session: session)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeStore.shared.current.chromeBackground)
        // chips/胶囊/按钮组自带胶囊样式,macOS 26 需隐藏系统工具栏 item 的玻璃底,避免双层背景
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    leadingControls
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    leadingControls
                }
            }
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .principal) {
                    if let session = sessionManager.selected {
                        SessionTitleCapsule(session: session)
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) {
                    if let session = sessionManager.selected {
                        SessionTitleCapsule(session: session)
                    }
                }
            }
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) {
                    panelButtons
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    panelButtons
                }
            }
        }
        .alert(
            "关闭分屏「\(sessionManager.pendingCloseSession?.displayTitle ?? "")」?",
            isPresented: Binding(
                get: { manager.pendingCloseSession != nil },
                set: { if !$0 { manager.pendingCloseSession = nil } }
            )
        ) {
            Button("终止并关闭", role: .destructive) {
                if let session = sessionManager.pendingCloseSession {
                    sessionManager.closePane(session)
                }
                manager.pendingCloseSession = nil
            }
            Button("取消", role: .cancel) { manager.pendingCloseSession = nil }
        } message: {
            Text("该分屏正有命令在运行。")
        }
        .alert(
            "关闭标签页?",
            isPresented: Binding(
                get: { manager.pendingCloseTab != nil },
                set: { if !$0 { manager.pendingCloseTab = nil } }
            )
        ) {
            Button("终止并关闭", role: .destructive) {
                if let tab = sessionManager.pendingCloseTab {
                    sessionManager.closeTab(tab)
                }
                manager.pendingCloseTab = nil
            }
            Button("取消", role: .cancel) { manager.pendingCloseTab = nil }
        } message: {
            Text("该标签页有命令正在运行(可能有多个分屏)。")
        }
    }

    private func hasActivity(_ tab: PaneTab) -> Bool {
        tab.root.leafIDs().contains { sessionManager.session($0)?.hasUnseenActivity == true }
    }

    /// 标题栏左侧:侧边栏切换 + 标签 chips + 新建标签(「+」贴着标签条,符合浏览器习惯)
    private var leadingControls: some View {
        HStack(spacing: 6) {
            if let toggleSidebar {
                PanelIconButton(symbol: "sidebar.leading", help: String(localized: "显示 / 隐藏侧边栏")) {
                    toggleSidebar()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RaisedCapsule())
            }
            if !sessionManager.tabs.isEmpty {
                tabChips
                PanelIconButton(symbol: "plus", help: String(localized: "新建标签页(⌘T)")) {
                    sessionManager.newTab()
                }
            }
        }
    }

    /// 标签条溢出可滚动时才显示两端渐隐,避免内容未满时文字被无故淡掉
    private var chipsOverflow: Bool {
        chipsContentWidth > chipsContainerWidth + 1
    }

    /// 标签条轨道:比标题栏底色再暗一档,内凹感,把所有 chips 收进同一个容器
    private var chipTrackColor: Color {
        let theme = ThemeStore.shared.current
        return Color(nsColor: theme.backgroundNSColor.mixed(with: .black, ratio: theme.isDark ? 0.22 : 0.05))
    }

    /// 标签 chips(标题栏左侧):深色轨道内选中浮起,溢出时两端渐隐,选中自动滚入
    private var tabChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(sessionManager.tabs) { tab in
                        TerminalTabChip(
                            tab: tab,
                            focusedSession: sessionManager.session(tab.focusedID),
                            paneCount: tab.root.leafIDs().count,
                            isSelected: tab.id == sessionManager.selectedTabID,
                            hasActivity: hasActivity(tab),
                            select: { sessionManager.selectTab(tab.id) },
                            close: { sessionManager.requestCloseTab(tab) }
                        )
                        .id(tab.id)
                        .contextMenu {
                            Button("移到新窗口") {
                                sessionManager.detachTabToNewWindow(tab)
                                openWindow(id: "main", value: UUID())
                            }
                            .disabled(sessionManager.tabs.count < 2)
                            Button("关闭标签页", role: .destructive) {
                                sessionManager.requestCloseTab(tab)
                            }
                        }
                        // 拖拽重排:拖起 chip 丢到另一枚 chip 上,占据其位置
                        .draggable(tab.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let raw = items.first, let dragged = UUID(uuidString: raw) else { return false }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                sessionManager.moveTab(dragged, before: tab.id)
                            }
                            return true
                        }
                    }
                }
                .padding(.horizontal, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipsContentWidth = $0 }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipsContainerWidth = $0 }
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [chipsOverflow ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 12)
                    Color.black
                    LinearGradient(colors: [.black, chipsOverflow ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 12)
                }
            )
            // 背景加在 mask 之后:轨道本身不参与两端渐隐。
            // 内阴影让轨道真正"凹进去",避免纯平色块的廉价感
            .padding(3)
            .background(
                Capsule().fill(
                    chipTrackColor.shadow(.inner(
                        color: .black.opacity(ThemeStore.shared.current.isDark ? 0.4 : 0.1),
                        radius: 1.5, y: 1
                    ))
                )
            )
            .onChange(of: sessionManager.selectedTabID) { _, selected in
                guard let selected else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(selected, anchor: .center) }
            }
        }
    }

    /// 标题栏右侧按钮组:面板开关(时间线 / Git / 文件)+ 主题面板
    private var panelButtons: some View {
        HStack(spacing: 2) {
            PanelIconButton(
                symbol: "clock.arrow.circlepath",
                help: String(localized: "命令时间线(⌘I)"),
                tint: sessionManager.isTimelineVisible ? ThemeStore.shared.current.accentColor : nil
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    sessionManager.toggleTimeline()
                }
            }
            PanelIconButton(
                symbol: "arrow.trianglehead.branch",
                help: String(localized: "Git 面板(⌘G)"),
                tint: sessionManager.isGitPanelVisible ? ThemeStore.shared.current.accentColor : nil
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    sessionManager.toggleGitPanel()
                }
            }
            PanelIconButton(
                symbol: "folder",
                help: String(localized: "文件浏览器(⇧⌘E)"),
                tint: sessionManager.isFileBrowserVisible ? ThemeStore.shared.current.accentColor : nil
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    sessionManager.toggleFileBrowser()
                }
            }
            ThemePanelButton()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RaisedCapsule())
    }

    /// 广播模式横幅:提示所有分屏同步接收键入
    private var broadcastBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 10))
            Text("广播输入:键入同步到当前标签所有分屏")
                .font(.system(size: 11, weight: .medium))
            Spacer()
            Button("停止") { sessionManager.toggleBroadcast() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.85))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Button {
                sessionManager.newTab()
            } label: {
                Label("新建标签页", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            Text("⌘T 新建 · ⌘D 分屏 · ⌘P 命令面板")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 浮起材质胶囊:投影 + 顶部受光细边。选中标签、标题栏按钮共用同一套光影语言
struct RaisedCapsule: View {
    var body: some View {
        let theme = ThemeStore.shared.current
        Capsule()
            .fill(theme.elevatedBackground.shadow(.drop(
                color: .black.opacity(theme.isDark ? 0.35 : 0.15),
                radius: 1.5, y: 1
            )))
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(theme.isDark ? 0.16 : 0.6), .white.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
    }
}

/// 标题栏右上的圆形悬停按钮
struct PanelIconButton: View {
    let symbol: String
    let help: String
    var tint: Color?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 主题面板按钮(popover 色卡网格)
private struct ThemePanelButton: View {
    @State private var showing = false

    var body: some View {
        PanelIconButton(symbol: "paintpalette", help: String(localized: "终端配色")) {
            showing.toggle()
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ThemePanelView()
        }
    }
}

/// 标题栏中央的会话信息胶囊:shell 名 + 工作目录,点按在 Finder 中打开
private struct SessionTitleCapsule: View {
    let session: TerminalSession

    @State private var hovering = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    private var directoryText: String {
        guard let dir = session.workingDirectory else { return "" }
        return (dir as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        Button {
            if let dir = session.workingDirectory {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
            }
        } label: {
            HStack(spacing: 7) {
                // 运行中是常态不提示,仅退出时红点示警(与标签 chips 的规则一致)
                if session.state != .running {
                    Circle()
                        .fill(Color.red.opacity(0.8))
                        .frame(width: 6, height: 6)
                }
                Text(session.shellName)
                    .font(.system(size: 12, weight: .medium))
                if !directoryText.isEmpty {
                    Text(directoryText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 380)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            // 纯信息展示不需要一直"装在盒子里",悬停时才显形提示可点
            .background(
                Capsule().fill(hovering ? Color.primary.opacity(0.06) : .clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help("在 Finder 中打开 \(directoryText)")
    }
}

/// 分屏树递归视图:叶子=一个终端 pane(可点按聚焦、聚焦有强调边框),
/// 分支=按 ratio 二分,中间分隔条可拖拽调整比例
private struct PaneTreeView: View {
    let node: PaneNode
    let focusedID: UUID
    var showsFocus: Bool = true
    var broadcasting: Bool = false
    let onFocus: (UUID) -> Void
    let onResize: (UUID, Double) -> Void
    @Environment(SessionManager.self) private var sessionManager

    /// 分隔条命中区厚度(可见线仍是 1pt)
    private static let dividerThickness: CGFloat = 7

    var body: some View {
        switch node {
        case .leaf(let sid):
            if let session = sessionManager.session(sid) {
                TerminalPaneView(session: session)
                    .id(sid)
                    .overlay(
                        Rectangle()
                            .stroke(borderColor(sid), lineWidth: 1.5)
                            .allowsHitTesting(false)
                    )
                    // 点非聚焦 pane 时先聚焦(不吞掉终端本身的交互)
                    .onTapGesture { if sid != focusedID { onFocus(sid) } }
            } else {
                Color.clear
            }
        case .branch(let branchID, let axis, let ratio, let first, let second):
            GeometryReader { geo in
                let total = (axis == .horizontal ? geo.size.width : geo.size.height) - Self.dividerThickness
                let firstLength = max(0, total * ratio)
                let secondLength = max(0, total - firstLength)
                let layout = axis == .horizontal
                    ? AnyLayout(HStackLayout(spacing: 0))
                    : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    subtree(first)
                        .frame(
                            width: axis == .horizontal ? firstLength : nil,
                            height: axis == .vertical ? firstLength : nil
                        )
                    PaneDivider(axis: axis) { location in
                        let position = axis == .horizontal ? location.x : location.y
                        guard total > 0 else { return }
                        onResize(branchID, position / total)
                    }
                    .frame(
                        width: axis == .horizontal ? Self.dividerThickness : nil,
                        height: axis == .vertical ? Self.dividerThickness : nil
                    )
                    subtree(second)
                        .frame(
                            width: axis == .horizontal ? secondLength : nil,
                            height: axis == .vertical ? secondLength : nil
                        )
                }
                .coordinateSpace(name: branchID)
                // 分隔条经环境拿到所属分支的坐标系名(嵌套分支各自覆盖)
                .environment(\.paneBranchSpace, branchID)
            }
        }
    }

    private func subtree(_ child: PaneNode) -> some View {
        PaneTreeView(
            node: child,
            focusedID: focusedID,
            showsFocus: showsFocus,
            broadcasting: broadcasting,
            onFocus: onFocus,
            onResize: onResize
        )
    }

    private func borderColor(_ sid: UUID) -> Color {
        // 广播时所有 pane 橙色边框;否则仅聚焦 pane 强调色边框
        if broadcasting { return .orange.opacity(0.7) }
        if showsFocus, sid == focusedID { return ThemeStore.shared.current.accentColor.opacity(0.55) }
        return .clear
    }
}

/// 可拖拽分隔条:1pt 可见线 + 7pt 命中区,悬停变宽度光标,拖动回报在父分支坐标系中的位置
private struct PaneDivider: View {
    let axis: SplitAxis
    /// 拖动中回调:location 为分支容器坐标系中的当前位置
    let onDrag: (CGPoint) -> Void

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
            Rectangle()
                .fill(
                    dragging || hovering
                        ? ThemeStore.shared.current.accentColor.opacity(0.6)
                        : ThemeStore.shared.current.borderColor
                )
                .frame(
                    width: axis == .horizontal ? (dragging || hovering ? 3 : 1) : nil,
                    height: axis == .vertical ? (dragging || hovering ? 3 : 1) : nil
                )
        }
        .onHover { inside in
            hovering = inside
            if inside {
                (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(parentSpaceName))
                .onChanged { value in
                    dragging = true
                    onDrag(value.location)
                }
                .onEnded { _ in dragging = false }
        )
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// 分隔条的 DragGesture 需要在「分支容器」坐标系取位置;由父视图 .coordinateSpace(name: branchID) 提供。
    /// SwiftUI 无法从子视图直接引用父的 name,这里由父视图在创建时保证唯一层级 —— 用 EnvironmentKey 传递。
    @Environment(\.paneBranchSpace) private var parentSpaceName
}

private struct PaneBranchSpaceKey: EnvironmentKey {
    static let defaultValue: UUID = UUID()
}

extension EnvironmentValues {
    var paneBranchSpace: UUID {
        get { self[PaneBranchSpaceKey.self] }
        set { self[PaneBranchSpaceKey.self] = newValue }
    }
}

private struct TerminalTabChip: View {
    let tab: PaneTab
    let focusedSession: TerminalSession?
    let paneCount: Int
    let isSelected: Bool
    var hasActivity = false
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            // 圆点只承载例外状态:命令在跑转菊花、后台新输出强调色点、进程退出红点;
            // 空闲是常态,不显示指示,避免整排绿点噪音
            if focusedSession?.runningCommand == true {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 8, height: 8)
            } else if hasActivity, !isSelected {
                Circle()
                    .fill(ThemeStore.shared.current.accentColor)
                    .frame(width: 7, height: 7)
                    .help("有新输出")
            } else if case .exited = focusedSession?.state {
                Circle()
                    .fill(Color.red.opacity(0.8))
                    .frame(width: 6, height: 6)
                    .help("进程已退出")
            }
            Text(focusedSession?.displayTitle ?? String(localized: "终端"))
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: 150)
            if paneCount > 1 {
                Text("\(paneCount)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .help("\(paneCount) 个分屏")
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 0.7 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background {
            // 深色轨道内:选中 chip 用浮起材质,未选中保持透明、悬停微亮
            if isSelected {
                RaisedCapsule()
            } else if isHovering {
                Capsule().fill(Color.primary.opacity(0.05))
            }
        }
        .foregroundStyle(isSelected ? .primary : .secondary)
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
    }
}

/// 单个会话面板:终端 + ⌘F 搜索条覆盖层
struct TerminalPaneView: View {
    @Bindable var session: TerminalSession
    @Environment(SessionManager.self) private var sessionManager

    @State private var searchModel = TerminalSearchModel()
    @State private var isSearchActive = false

    var body: some View {
        ZStack(alignment: .top) {
            TerminalHostView(terminalView: session.terminalView)
                .padding(.leading, 8)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: ThemeStore.shared.current.backgroundNSColor))

            if isSearchActive {
                HStack {
                    Spacer()
                    TerminalSearchBar(model: searchModel) {
                        isSearchActive = false
                        searchModel.close()
                        session.focusTerminal()
                    }
                    .padding(.trailing, 12)
                }
            }
        }
        .onChange(of: sessionManager.searchRequestToken) { _, _ in
            // 只有当前选中会话响应 ⌘F
            guard session.id == sessionManager.selectedID else { return }
            searchModel.terminalView = session.terminalView
            isSearchActive = true
        }
    }
}
