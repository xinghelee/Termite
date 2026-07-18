import SwiftUI

/// 终端区:标签 chips(标题栏)+ 当前标签的分屏树 + 底部状态栏
struct TerminalTabsView: View {
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var manager = sessionManager
        VStack(spacing: 0) {
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
                    if !sessionManager.tabs.isEmpty { tabChips }
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    if !sessionManager.tabs.isEmpty { tabChips }
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

    /// 标签 chips(标题栏左侧):两端渐隐,选中自动滚入
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
                .padding(.horizontal, 10)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 12)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 12)
                }
            )
            .onChange(of: sessionManager.selectedTabID) { _, selected in
                guard let selected else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(selected, anchor: .center) }
            }
        }
    }

    /// 标题栏右侧按钮组:新建标签 + 命令时间线 + 主题面板
    private var panelButtons: some View {
        HStack(spacing: 2) {
            PanelIconButton(symbol: "plus", help: String(localized: "新建标签页(⌘T)")) {
                sessionManager.newTab()
            }
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
            ThemePanelButton()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(ThemeStore.shared.current.elevatedBackground)
                .overlay(Capsule().stroke(ThemeStore.shared.current.borderColor, lineWidth: 1))
        )
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
                Circle()
                    .fill(session.state == .running ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
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
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(theme.elevatedBackground)
                    .overlay(
                        Capsule().stroke(
                            hovering ? theme.accentColor.opacity(0.4) : theme.borderColor,
                            lineWidth: 1
                        )
                    )
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
            // 有命令在跑时旋转指示;后台有新输出时强调色大点;空闲绿色圆点
            if focusedSession?.runningCommand == true {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 8, height: 8)
            } else if hasActivity, !isSelected {
                Circle()
                    .fill(ThemeStore.shared.current.accentColor)
                    .frame(width: 7, height: 7)
                    .help("有新输出")
            } else {
                Circle()
                    .fill(stateColor)
                    .frame(width: 6, height: 6)
            }
            Text(focusedSession?.displayTitle ?? String(localized: "终端"))
                .font(.system(size: 12))
                .lineLimit(1)
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
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(isSelected ? ThemeStore.shared.current.accentSoft : (isHovering ? Color.primary.opacity(0.06) : .clear))
        )
        .overlay(
            Capsule()
                .stroke(isSelected ? ThemeStore.shared.current.accentColor.opacity(0.35) : .clear, lineWidth: 1)
        )
        .foregroundStyle(isSelected ? .primary : .secondary)
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
    }

    private var stateColor: Color {
        switch focusedSession?.state {
        case .running: return .green
        case .exited, .none: return .gray
        }
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
