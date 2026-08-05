import SwiftUI

/// 终端区:标签 chips(标题栏)+ 当前标签的分屏树 + 底部状态栏
struct TerminalTabsView: View {
    /// 侧边栏切换(系统按钮已移除,由这里统一样式渲染);nil 时不显示
    var toggleSidebar: (() -> Void)? = nil

    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.openWindow) private var openWindow
    @State private var chipsContentWidth: CGFloat = 0
    @State private var chipsContainerWidth: CGFloat = 0
    // 标签拖排(AppKit mouseDragged 驱动,chip 的事件层上报窗口坐标 ΔX)。
    // 不能用 .draggable(item-provider 拖起不算手势,标题栏里抢不过 window-move);
    // 也不能用 DragGesture:macOS 15 的标题栏拖窗机制在 SwiftUI 手势判定前就接管,
    // 按住 chip 移动的仍是整个窗口(issue #9 两度复发),26 的新工具栏才让手势赢
    @State private var chipFrames: [UUID: CGRect] = [:]
    @State private var draggingChip: UUID?
    @State private var dragOffset: CGFloat = 0
    /// 越线换位的累计补偿:视觉偏移 = 指针 ΔX − 已换位宽度,换位瞬间零跳变
    @State private var dragSwapShift: CGFloat = 0
    private static let chipTrackSpace = "chipTrack"
    /// chips HStack 的间距,交换补偿时参与位移计算
    private static let chipSpacing: CGFloat = 2
    @AppStorage(SettingsKeys.translucentChrome) private var translucentChrome = true
    /// 终端区宽度:标签轨道的动态上限基准(超宽会让 NSToolbar 整体收进 » 溢出菜单)
    @State private var contentWidth: CGFloat = 0
    /// 右侧按钮岛实测宽(升级/巡视按钮会动态出现,写死会算漏导致 » 折叠)
    @State private var panelWidth: CGFloat = 150

    var body: some View {
        @Bindable var manager = sessionManager
        VStack(spacing: 0) {
            // 标题栏与终端区同色,一条发丝线划出结构边界
            Rectangle()
                .fill(ThemeStore.shared.current.borderColor)
                .frame(height: 1)
            if sessionManager.visibleTabs.isEmpty {
                // 真空窗口或空工作区(白纸)都回欢迎面板
                emptyState
            } else if let tab = sessionManager.selectedTab {
                if tab.isBroadcasting {
                    broadcastBanner
                }
                HStack(spacing: 0) {
                    if tab.isCarousel, tab.root.leafIDs().count > 1 {
                        PaneCarouselView(tab: tab)
                    } else if let maximizedID = tab.maximizedID,
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
                            sessionManager.layoutChangedSoon()
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        // 「在新 Worktree 中分屏」居中模态(遮罩点击即取消)
        .overlay {
            if let prompting = sessionManager.sessions.first(where: { $0.worktreePromptPresented }) {
                ZStack {
                    Color.black.opacity(0.25)
                        .onTapGesture {
                            prompting.worktreePromptPresented = false
                            prompting.focusTerminal()
                        }
                    WorktreePromptView(session: prompting)
                }
            }
        }
        // chips/胶囊/按钮组自带胶囊样式,macOS 26 需隐藏系统工具栏 item 的玻璃底,避免双层背景
        .toolbar {
            // 中间必须有弹性空间:没有它(原标题胶囊撤走后)右侧按钮组会塌到标签旁边;
            // 弹开的中间区域归标签轨道用(轨道上限已放开)
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    leadingControls
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible)
                ToolbarItem(placement: .primaryAction) {
                    panelButtons
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    leadingControls
                }
                ToolbarItem {
                    Spacer()
                }
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

    private func hasAttention(_ tab: PaneTab) -> Bool {
        tab.root.leafIDs().contains { sessionManager.session($0)?.attention.needsInput == true }
    }

    /// 标题栏左侧:侧边栏切换(裸图标,原生惯例;单独装胶囊会成为整排最亮的孤岛)+ 标签轨道
    private var leadingControls: some View {
        HStack(spacing: 6) {
            if let toggleSidebar {
                // prominent:26+ 自绘常驻玻璃圆底,对齐右侧按钮组的系统风格;
                // 旧系统仍是裸图标+悬停圆,与全排一致
                PanelIconButton(
                    symbol: "sidebar.leading",
                    help: String(localized: "显示 / 隐藏侧边栏"),
                    prominent: true
                ) {
                    toggleSidebar()
                }
            }
            if !sessionManager.visibleTabs.isEmpty {
                tabChips
            }
        }
    }

    /// 标签条溢出可滚动时才显示两端渐隐,避免内容未满时文字被无故淡掉
    private var chipsOverflow: Bool {
        chipsContentWidth > chipsContainerWidth + 1
    }

    /// 标签条轨道:内凹感,把所有 chips 收进同一个容器。
    /// 透明 chrome 下用半透黑压出凹槽(不透明的 trackBackground 在玻璃上是一块死黑,
    /// 用户反馈「背景太黑」);不透明模式仍是比 chrome 带再暗一档的实色
    private var chipTrackColor: Color {
        translucentChrome
            ? Color.black.opacity(ThemeStore.shared.current.isDark ? 0.28 : 0.08)
            : ThemeStore.shared.current.trackBackground
    }

    /// 标签 chips(标题栏左侧):深色轨道内选中浮起,溢出时两端渐隐,选中自动滚入;
    /// 「+」收进轨道尾端与 chips 同一容器(浏览器习惯),不再裸悬在轨道外
    private var tabChips: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 2) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        // 只展示当前项目的标签(+ 无归属的散标签);切项目走侧边栏
                        ForEach(sessionManager.visibleTabs) { tab in
                            TerminalTabChip(
                                tab: tab,
                                focusedSession: sessionManager.session(tab.focusedID),
                                paneCount: tab.root.leafIDs().count,
                                isSelected: tab.id == sessionManager.selectedTabID,
                                hasActivity: hasActivity(tab),
                                hasAttention: hasAttention(tab),
                                select: { sessionManager.selectTab(tab.id) },
                                close: { sessionManager.requestCloseTab(tab) },
                                dragChanged: { chipDragChanged(tab, deltaX: $0) },
                                dragEnded: { chipDragEnded(tab) }
                            )
                            .id(tab.id)
                            .contextMenu {
                                Button("重命名") {
                                    sessionManager.selectTab(tab.id)
                                    tab.isRenaming = true
                                }
                                Button("移到新窗口") {
                                    sessionManager.detachTabToNewWindow(tab)
                                    openWindow(id: "main", value: UUID())
                                }
                                .disabled(sessionManager.tabs.count < 2)
                                Button("关闭标签页", role: .destructive) {
                                    sessionManager.requestCloseTab(tab)
                                }
                            }
                            // 关闭缩小淡出 / 新建对称弹入(定位滚动保持瞬时,不与此动画打架)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                            // 拖拽重排:跟手平移,越过邻居中线即换位(浏览器手感)
                            .offset(x: draggingChip == tab.id ? dragOffset : 0)
                            .zIndex(draggingChip == tab.id ? 1 : 0)
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .named(Self.chipTrackSpace))
                            } action: { chipFrames[tab.id] = $0 }
                        }
                    }
                    .padding(.horizontal, 4)
                    // 拖排进行中即时换位不动画:换位动画期间 chip frame 在飞,
                    // 越线判定会拿飞行中的坐标连环误换
                    .animation(draggingChip == nil ? .spring(response: 0.25, dampingFraction: 0.9) : nil,
                               value: sessionManager.visibleTabs.map(\.id))
                    .coordinateSpace(name: Self.chipTrackSpace)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipsContentWidth = $0 }
                }
                // minWidth 让窄窗口时工具栏压缩标签条(可滚动)而不是整个丢弃(issue #4 三)。
                // 上限动态跟随终端区宽度,预留 = 按钮岛实宽 + 红绿灯/侧边栏钮/边距(200):
                // 标题栏中段全归标签,超出就轨道内滚动;算漏预留会让 NSToolbar 收进 » 菜单
                .frame(minWidth: 96, maxWidth: max(96, contentWidth - panelWidth - 200), alignment: .leading)
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
                PanelIconButton(symbol: "plus", help: String(localized: "新建标签页(⌘T)")) {
                    sessionManager.newTab()
                }
            }
            // 背景加在 mask 之后:轨道本身不参与两端渐隐。
            // 内阴影让轨道真正"凹进去",避免纯平色块的廉价感;
            // 垂直 padding 4:chip 上下各留一道可见的沟,不贴着轨道边缘
            .padding(.horizontal, 3)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    chipTrackColor.shadow(.inner(
                        color: .black.opacity(ThemeStore.shared.current.isDark ? 0.4 : 0.1),
                        radius: 1.5, y: 1
                    ))
                )
            )
            // 近黑主题下「比背景再暗一档」压不出对比,发丝描边兜底勾出轨道轮廓
            .overlay(
                Capsule().strokeBorder(ThemeStore.shared.current.borderColor, lineWidth: 1)
            )
            .onChange(of: sessionManager.selectedTabID) { _, selected in
                guard let selected else { return }
                // 瞬时定位:新建标签时 chip 插入与滚动两个动画打架会抖(issue #4 四)
                proxy.scrollTo(selected, anchor: .center)
            }
        }
    }

    /// chip 拖排(事件层上报窗口坐标 ΔX,方向与轨道一致):chip 钉在指针下,
    /// 越过邻居中线即换位;越线判定仍用轨道坐标系的 frame 快照,ΔX 是纯相对量,两系通用
    private func chipDragChanged(_ tab: PaneTab, deltaX: CGFloat) {
        if draggingChip != tab.id {
            draggingChip = tab.id
            dragSwapShift = 0
        }
        dragOffset = deltaX - dragSwapShift
        swapIfCrossedNeighbor(tab)
    }

    private func chipDragEnded(_ tab: PaneTab) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            dragOffset = 0
        }
        // 等落位动画放完再摘拖拽态(期间保持 zIndex 抬高;新拖动会自行接管)
        let settled = tab.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if draggingChip == settled { draggingChip = nil }
        }
    }

    /// 越线判定与换位。全部用本轮事件的旧布局坐标快照比较;换位后邻居的
    /// 陈旧 frame 会落在错误的一侧,side 校验自然拦下连环误换
    private func swapIfCrossedNeighbor(_ tab: PaneTab) {
        guard let myFrame = chipFrames[tab.id] else { return }
        let center = myFrame.midX + dragOffset
        let visible = sessionManager.visibleTabs
        guard let myIndex = visible.firstIndex(where: { $0.id == tab.id }) else { return }

        var target = myIndex
        var shift: CGFloat = 0
        var i = myIndex + 1
        while i < visible.count, let f = chipFrames[visible[i].id],
              f.midX > myFrame.midX, center > f.midX {
            target = i
            shift += f.width + Self.chipSpacing
            i += 1
        }
        if target > myIndex {
            sessionManager.moveTab(tab.id, after: visible[target].id)
            dragSwapShift += shift
            dragOffset -= shift
            return
        }

        i = myIndex - 1
        while i >= 0, let f = chipFrames[visible[i].id],
              f.midX < myFrame.midX, center < f.midX {
            target = i
            shift += f.width + Self.chipSpacing
            i -= 1
        }
        if target < myIndex {
            sessionManager.moveTab(tab.id, before: visible[target].id)
            dragSwapShift -= shift
            dragOffset += shift
        }
    }

    /// 标题栏右侧按钮组:面板开关(时间线 / Git / 文件)+ 主题面板;有新版时头部多一枚下载入口
    private var panelButtons: some View {
        HStack(spacing: 2) {
            if let update = UpdateChecker.shared.available {
                PanelIconButton(
                    symbol: "arrow.down.circle.fill",
                    help: String(localized: "升级到 Termite \(update.version)"),
                    tint: ThemeStore.shared.current.accentColor
                ) {
                    UpdateChecker.shared.openDownload()
                }
            }
            if let tab = sessionManager.selectedTab, tab.root.leafIDs().count > 1 {
                PanelIconButton(
                    symbol: "rectangle.split.3x1",
                    help: String(localized: "巡视分屏:等宽横排滑动(⇧⌘\\)"),
                    tint: tab.isCarousel ? ThemeStore.shared.current.accentColor : nil
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        sessionManager.toggleCarousel()
                    }
                }
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { panelWidth = $0 }
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
        // 「空窗口自动新建终端」的自动补标签**不能**挂在这里:欢迎页每次出现都会触发,
        // 关掉最后一个标签就会被立刻补一个,标签看着永远关不掉(issue #7)。
        // 改由 SessionManager 在窗口打开那一刻补一次
    }
}

/// 浮起材质胶囊:选中标签、标题栏按钮、选中项目行共用同一套光影语言。
/// macOS 26+ 用系统 Liquid Glass(真实折射 + 边缘受光,与原生 chrome 同材质),
/// 旧系统回退自绘:纯色底 + 投影 + 顶部受光细边
struct RaisedCapsule: View {
    var body: some View {
        let theme = ThemeStore.shared.current
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: .capsule)
        } else {
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
}

/// 标题栏右上的圆形悬停按钮
struct PanelIconButton: View {
    let symbol: String
    let help: String
    var tint: Color?
    /// 常驻玻璃圆底(macOS 26)。系统只给 primaryAction 位的按钮内省加圆底,
    /// .navigation 位(侧边栏开关)拿不到,自绘一枚对齐右侧按钮组的风格
    var prominent = false
    let action: () -> Void

    @State private var hovering = false

    /// 旧系统没有玻璃圆底,28pt 容器只在 26+ 随圆底一起生效,
    /// 15 上保持 24pt 与全排图标钮一致(不引入版本间视觉分裂)
    private var effectiveSide: CGFloat {
        guard prominent else { return 24 }
        if #available(macOS 26.0, *) { return 28 }
        return 24
    }

    var body: some View {
        // 常驻圆底的按钮加大内间距(28pt),图标四周留足呼吸感;
        // 容器必须是正方形——玻璃/悬停底才是正圆而不是椭圆
        let side = effectiveSide
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: side, height: side)
                .background {
                    if prominent, #available(macOS 26.0, *) {
                        // 玻璃自己钉死正方形再画圆:背景吃外层尺寸提议时
                        // 曾被拉成 29×27 的椭圆(用户截图实测),不能信任提议
                        Color.clear
                            .glassEffect(.regular, in: .circle)
                            .frame(width: side, height: side)
                    }
                }
                .background(Circle().fill(hovering ? Color.primary.opacity(0.08) : .clear))
                // 悬停轻微浮起,与「选中 = 浮起」一个语言;按下回缩在 ButtonStyle 里
                .scaleEffect(hovering ? 1.06 : 1)
        }
        .buttonStyle(PressableIconStyle())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 图标钮按下回缩:.plain 没有任何按压反馈,鼠标按下瞬间给一点物理感
private struct PressableIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
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

/// 巡视模式的横滑改道:SwiftTerm 吞掉 deltaY==0 的滚动且 scrollWheel 不可覆写,
/// 横滑到不了外层分页 ScrollView。本地事件监视器按手势起始的主导轴分流:
/// 落在终端上的横向手势(含惯性,整段同一路由)喂给分页容器,竖向仍是终端回滚。
/// 仅巡视视图在屏时安装(引用计数,多窗口各自巡视也只装一个监视器);
/// 平铺模式下终端没有 NSScrollView 祖先,天然不接管
@MainActor
private final class CarouselScrollRouter {
    static let shared = CarouselScrollRouter()
    private var monitor: Any?
    private var installCount = 0
    /// 本轮触控板手势是否已判定为横滑
    private var routing = false

    func install() {
        installCount += 1
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.route(event) ?? event
        }
    }

    func remove() {
        installCount = max(0, installCount - 1)
        guard installCount == 0, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        routing = false
    }

    private func route(_ event: NSEvent) -> NSEvent? {
        guard let content = event.window?.contentView else { return event }
        let point = content.convert(event.locationInWindow, from: nil)
        guard let hit = content.hitTest(point) else { return event }
        var terminal: NSView?
        var cursor: NSView? = hit
        while let view = cursor {
            if view is TermiteTerminalView { terminal = view; break }
            cursor = view.superview
        }
        guard let terminal else { routing = false; return event }
        var pager: NSScrollView?
        cursor = terminal.superview
        while let view = cursor {
            if let scrollView = view as? NSScrollView { pager = scrollView; break }
            cursor = view.superview
        }
        guard let pager else { routing = false; return event }
        if event.phase == .began || (event.phase == [] && event.momentumPhase == []) {
            routing = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        guard routing else { return event }
        pager.scrollWheel(with: event)
        if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
            routing = false
        }
        return nil
    }
}

/// 巡视模式(⇧⌘\):当前标签所有 pane 等宽横排、分页吸附滑动;
/// 滑到哪页焦点就到哪个 pane(顺带消解注意力),点击部分露出的 pane 也会吸附过去。
/// 布局树不参与渲染但原样保留,退出即还原
private struct PaneCarouselView: View {
    let tab: PaneTab
    @Environment(SessionManager.self) private var sessionManager
    /// 当前吸附的 pane(scrollPosition 双向同步;与 focusedID 互跟,靠值判等防环)
    @State private var snappedID: UUID?

    var body: some View {
        let leaves = tab.root.leafIDs()
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(leaves, id: \.self) { sid in
                    if let session = sessionManager.session(sid) {
                        PaneLeafView(
                            session: session,
                            isFocused: sid == tab.focusedID,
                            showsFocus: true,
                            broadcasting: tab.isBroadcasting,
                            onFocus: { sessionManager.focusPane(sid) }
                        )
                        // 50% 宽:一屏并排看到两页
                        .containerRelativeFrame(.horizontal) { length, _ in length * 0.50 }
                        .id(sid)
                    }
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 12, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $snappedID)
        .onChange(of: snappedID) { _, snapped in
            // 翻到哪页都把全部 pane 标脏:屏外挂载的 Metal 图层可能停摆,
            // 缓冲区有内容却不画,滑到面前是空白
            for sid in tab.root.leafIDs() {
                sessionManager.session(sid)?.terminalView.needsDisplay = true
            }
            guard let snapped, snapped != tab.focusedID else { return }
            sessionManager.focusPane(snapped)
        }
        .onChange(of: tab.focusedID) { _, focused in
            guard snappedID != focused else { return }
            withAnimation(.easeOut(duration: 0.25)) { snappedID = focused }
        }
        .onAppear {
            snappedID = tab.focusedID
            CarouselScrollRouter.shared.install()
        }
        .onDisappear { CarouselScrollRouter.shared.remove() }
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
                PaneLeafView(
                    session: session,
                    isFocused: sid == focusedID,
                    showsFocus: showsFocus,
                    broadcasting: broadcasting,
                    onFocus: { onFocus(sid) }
                )
                .id(sid)
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
}

/// 叶子 pane:终端 + 状态边框(广播 / 等待输入呼吸 / 聚焦)+ 注意力徽标 + 命令结束闪烁
private struct PaneLeafView: View {
    let session: TerminalSession
    let isFocused: Bool
    let showsFocus: Bool
    let broadcasting: Bool
    let onFocus: () -> Void

    /// 命令结束的一次性边框闪烁(绿=成功,红=失败),动画淡出
    @State private var flashOpacity: Double = 0
    @State private var flashFailed = false
    /// 徽标右键「快速回复…」的气泡输入框
    @State private var quickReplyOpen = false

    /// 双击标题条改名的输入框状态
    @State private var renamePrompt = false
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            // 自定义分屏名 = 专属标题条(占布局空间,零遮挡;起了名才有,iTerm 惯例)
            if let name = session.customName {
                paneNameHeader(name)
            }
            TerminalPaneView(session: session)
        }
            .overlay(alignment: .bottom) {
                if session.composerDraft != nil {
                    CommandComposerView(session: session)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(
                Self.borderShape
                    .strokeBorder(flashFailed ? Color.red : Color.green, lineWidth: 2)
                    .opacity(flashOpacity)
                    .allowsHitTesting(false)
            )
            .overlay(borderOverlay)
            .overlay(alignment: .topTrailing) { attentionBadge }
            .alert("重命名分屏", isPresented: $renamePrompt) {
                TextField(session.displayTitle, text: $renameText)
                Button("确定") { session.setCustomName(renameText) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("留空恢复自动标题(目录 / 程序名)。")
            }
            // 点 pane 即聚焦并抢回键盘:即使 UI 已标聚焦,first responder 也可能
            // 在别处(滚动条/侧边栏),无条件 focusTerminal 让「点一下就能打字」永远成立
            .onTapGesture { onFocus() }
            .onChange(of: session.finishFlash) { _, flash in
                guard flash != nil, !isFocused else { return }
                flashFailed = flash?.failed == true
                flashOpacity = 0.9
                withAnimation(.easeOut(duration: 1.2)) { flashOpacity = 0 }
            }
    }

    /// 分屏专属标题条:名字 + 双击改名;与终端同宽,内容整体下移不遮字
    private func paneNameHeader(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tag.fill")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(ThemeStore.shared.current.chromeBackground)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            renameText = session.customName ?? ""
            renamePrompt = true
        }
        .help(String(localized: "双击重命名"))
    }

    /// pane 状态边框的形状:圆角跟窗口/卡片一个语言,方角在深色主题里太硬。
    /// strokeBorder 而非 stroke:stroke 的线骑在边界上,半条在视图外,
    /// pane 贴窗口边时右/底缘会被裁没
    private static let borderShape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    @ViewBuilder private var borderOverlay: some View {
        if broadcasting {
            // 广播时所有 pane 橙色边框
            Self.borderShape
                .strokeBorder(Color.orange.opacity(0.7), lineWidth: 1.5)
                .allowsHitTesting(false)
        } else if session.attention.needsInput {
            // 等待输入:橙色呼吸边框,把视线引过去
            Self.borderShape
                .strokeBorder(Color.orange, lineWidth: 2)
                .phaseAnimator([0.85, 0.3]) { border, phase in
                    border.opacity(phase)
                } animation: { _ in .easeInOut(duration: 0.8) }
                .allowsHitTesting(false)
        } else if showsFocus, isFocused {
            Self.borderShape
                .strokeBorder(ThemeStore.shared.current.accentColor.opacity(0.55), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var attentionBadge: some View {
        switch session.attention {
        case .needsInput:
            badge(String(localized: "等待输入"), symbol: "keyboard.badge.ellipsis", tint: .orange)
                // 右键快速回复:不切焦点就地打发掉 agent 的打断
                .contextMenu {
                    Button("回车确认") {
                        session.sendText("\r")
                        session.clearAttention()
                    }
                    Button("发送 y") {
                        session.sendText("y\r")
                        session.clearAttention()
                    }
                    Divider()
                    Button("快速回复…") { quickReplyOpen = true }
                }
                .popover(isPresented: $quickReplyOpen, arrowEdge: .bottom) {
                    QuickReplyPopover(session: session, isPresented: $quickReplyOpen)
                }
        case .finished(let failed):
            badge(failed ? String(localized: "命令失败") : String(localized: "已完成"),
                  symbol: failed ? "xmark.circle.fill" : "checkmark.circle.fill",
                  tint: failed ? .red : .green)
        case .none:
            EmptyView()
        }
    }

    /// pane 右上角的注意力徽标(点击整个 pane 即聚焦并消解)
    private func badge(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(tint.opacity(0.9)))
        .padding(8)
        .help(String(localized: "点击聚焦此分屏"))
    }
}

/// 「在新 Worktree 中分屏」居中模态:一个输入框身兼二职——输入新名字建分支,
/// 或模糊搜索已有分支(本地+远程)检出。几千分支不卡的关键:一次性加载进内存、
/// 匹配用 FuzzyMatcher、渲染只取前 50 条。↑↓ 选择,回车执行,Esc 取消
private struct WorktreePromptView: View {
    @Bindable var session: TerminalSession
    @Environment(SessionManager.self) private var sessionManager
    @State private var name = ""
    @State private var axis: SplitAxis = .horizontal
    @State private var branches: [WorktreeService.Branch]?
    @State private var selection = 0
    @FocusState private var focused: Bool

    private enum Option: Hashable {
        case create(String)
        case checkout(WorktreeService.Branch)
    }

    /// 结果列表:显式状态,由输入/分支加载事件驱动重算(计算属性曾与输入脱节)
    @State private var results: [Option] = []

    /// 首行「新建」(有输入时) + 模糊匹配的已有分支(最多 50 条,分数降序)
    private func refreshResults() {
        let query = name.trimmingCharacters(in: .whitespaces)
        var list: [Option] = query.isEmpty ? [] : [.create(query)]
        if let branches {
            let matches: [WorktreeService.Branch]
            if query.isEmpty {
                matches = Array(branches.prefix(50))
            } else {
                matches = branches
                    .compactMap { b in FuzzyMatcher.score(query: query, candidate: b.name).map { (b, $0) } }
                    .sorted { $0.1 > $1.1 }
                    .prefix(50)
                    .map(\.0)
            }
            list += matches.map { .checkout($0) }
        }
        results = list
        selection = 0
    }

    var body: some View {
        let options = results
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ThemeStore.shared.current.accentColor)
                Text("在新 Worktree 中分屏")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("目录与仓库同级 · 分屏名=分支名")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            TextField(String(localized: "新分支名,或搜索已有分支…"), text: $name)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .font(.system(size: 14, design: .monospaced))
                .focused($focused)
                .onSubmit { apply(options) }
                .onKeyPress(.upArrow) {
                    selection = max(0, selection - 1); return .handled
                }
                .onKeyPress(.downArrow) {
                    selection = min(max(0, options.count - 1), selection + 1); return .handled
                }
                .onChange(of: name) { _, _ in refreshResults() }
            optionList(options)
            HStack(spacing: 10) {
                // 巡航模式是横排队列,新 pane 只能向右追加,方向没得选
                if sessionManager.selectedTab?.isCarousel != true {
                    Picker("", selection: $axis) {
                        Image(systemName: "rectangle.split.2x1")
                            .help(String(localized: "左右分屏")).tag(SplitAxis.horizontal)
                        Image(systemName: "rectangle.split.1x2")
                            .help(String(localized: "上下分屏")).tag(SplitAxis.vertical)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.large)
                    .frame(width: 170)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle(options), action: { apply(options) })
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(options.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(ThemeStore.shared.current.borderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
        .onAppear {
            focused = true
            refreshResults()
            let cwd = session.workingDirectory
            Task {
                branches = (try? await WorktreeService.branches(near: cwd ?? ".")) ?? []
                refreshResults()
            }
        }
        .onExitCommand { dismiss() }
    }

    @ViewBuilder private func optionList(_ options: [Option]) -> some View {
        if branches == nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("加载分支…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .frame(height: 40)
        } else if options.isEmpty {
            Text("输入新分支名,或搜索已有分支")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .frame(height: 40)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                            optionRow(option, selected: index == min(selection, options.count - 1))
                                .id(index)
                                .onTapGesture {
                                    selection = index
                                    apply(options)
                                }
                        }
                    }
                }
                // 高度贴内容(行高约 28),条目多才滚动,少时不留空白
                .frame(height: min(220, CGFloat(options.count) * 28))
                .onChange(of: selection) { _, index in
                    proxy.scrollTo(index)
                }
            }
        }
    }

    private func optionRow(_ option: Option, selected: Bool) -> some View {
        HStack(spacing: 8) {
            switch option {
            case .create(let name):
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(ThemeStore.shared.current.accentColor)
                Text("新建分支")
                    .foregroundStyle(.secondary)
                Text(name).fontWeight(.semibold)
            case .checkout(let branch):
                Image(systemName: branch.worktreePath != nil ? "folder.badge.gearshape" : "arrow.triangle.branch")
                    .foregroundStyle(branch.worktreePath != nil
                        ? AnyShapeStyle(ThemeStore.shared.current.accentColor)
                        : AnyShapeStyle(.secondary))
                Text(branch.name)
                if branch.worktreePath != nil {
                    tagCapsule(String(localized: "已有 Worktree"), tinted: true)
                } else if branch.isRemote {
                    tagCapsule(String(localized: "远程"), tinted: false)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? ThemeStore.shared.current.accentColor.opacity(0.22) : .clear)
        )
        .contentShape(Rectangle())
    }

    /// 行尾小标签:「已有 Worktree」强调色 /「远程」灰
    private func tagCapsule(_ text: String, tinted: Bool) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(tinted
                ? ThemeStore.shared.current.accentColor.opacity(0.2)
                : Color.primary.opacity(0.12)))
            .foregroundStyle(tinted
                ? AnyShapeStyle(ThemeStore.shared.current.accentColor)
                : AnyShapeStyle(.secondary))
    }

    private func confirmTitle(_ options: [Option]) -> LocalizedStringKey {
        switch options[safe: min(selection, options.count - 1)] {
        case .checkout(let branch): branch.worktreePath != nil ? "打开" : "检出"
        default: "创建"
        }
    }

    private func apply(_ options: [Option]) {
        guard !options.isEmpty else { return }
        let target: WorktreeService.Target
        switch options[min(selection, options.count - 1)] {
        case .create(let name): target = .newBranch(name)
        case .checkout(let branch):
            // 已被检出的分支不能再 add,直接分屏进它已有的 worktree
            if let path = branch.worktreePath {
                target = .openWorktree(path: path, branch: branch.name)
            } else {
                target = .existing(branch.name)
            }
        }
        session.worktreePromptPresented = false
        // 巡航模式强制横向:队列里向右追加为新一页
        let effectiveAxis = sessionManager.selectedTab?.isCarousel == true ? .horizontal : axis
        sessionManager.splitIntoWorktree(target, axis: effectiveAxis)
    }

    private func dismiss() {
        session.worktreePromptPresented = false
        session.focusTerminal()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// ⌘E 命令行浮层编辑器:把提示符处已键入的命令捞出来,像文本一样自由编辑
/// (鼠标选择 / 多行 / 撤销),⌘↩ 回填并执行,↩ 仅回填,Esc 取消
private struct CommandComposerView: View {
    @Bindable var session: TerminalSession
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.system(size: FontPrefs.font().pointSize, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 64, maxHeight: 180)
                .focused($focused)
            HStack {
                Text("⌘↩ 回填并执行 · Esc 取消")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { session.cancelComposeCommand() }
                Button("回填") { session.applyComposedCommand(text, execute: false) }
                Button("回填并执行") { session.applyComposedCommand(text, execute: true) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(ThemeStore.shared.current.accentColor.opacity(0.5), lineWidth: 1)
        )
        .padding(12)
        .onAppear {
            text = session.composerDraft ?? ""
            focused = true
        }
        .onExitCommand { session.cancelComposeCommand() }
    }
}

/// 徽标「快速回复…」气泡:一行输入直接发进该 pane(回车或按钮发送,不切换焦点)
private struct QuickReplyPopover: View {
    let session: TerminalSession
    @Binding var isPresented: Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField(String(localized: "发送到该分屏"), text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .focused($focused)
                .onSubmit(send)
            Button("发送", action: send)
        }
        .padding(10)
        .onAppear { focused = true }
    }

    private func send() {
        defer { isPresented = false }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        session.sendText(line + "\r")
        session.clearAttention()
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
    var hasAttention = false
    let select: () -> Void
    let close: () -> Void
    /// 拖排回调(窗口坐标 ΔX):事件层直连父级的重排状态机
    let dragChanged: (CGFloat) -> Void
    let dragEnded: () -> Void

    @Environment(SessionManager.self) private var sessionManager
    @State private var isHovering = false
    @State private var editText = ""
    @FocusState private var renameFocused: Bool

    private var title: String {
        tab.customTitle ?? focusedSession?.displayTitle ?? String(localized: "终端")
    }

    private func commitRename() {
        guard tab.isRenaming else { return }
        sessionManager.renameTab(tab, to: editText)
        refocusTerminal()
    }

    /// TextField 收起后交还键盘:推迟一拍,否则它移出视图树时
    /// AppKit 会再分配一次 first responder(常落到相邻滚动条),把这次的抢回来
    private func refocusTerminal() {
        let manager = sessionManager
        DispatchQueue.main.async { manager.selected?.focusTerminal() }
    }

    var body: some View {
        HStack(spacing: 6) {
            // 圆点只承载例外状态:分屏等待输入橙点、命令在跑转菊花、后台新输出强调色点、
            // 进程退出红点;空闲是常态,不显示指示,避免整排绿点噪音
            if hasAttention {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .help("有分屏在等待输入")
            } else if focusedSession?.runningCommand == true {
                if focusedSession?.longRunningCommand == true {
                    // ssh / dev server 这类长驻进程:菊花永动太吵,降级为静态绿点
                    Circle()
                        .fill(Color.green.opacity(0.8))
                        .frame(width: 6, height: 6)
                        .help("长时间运行中")
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 8, height: 8)
                }
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
            if tab.isRenaming {
                TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(width: 130)
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand {
                        // Esc 放弃修改
                        tab.isRenaming = false
                        refocusTerminal()
                    }
                    .onAppear {
                        editText = title
                        renameFocused = true
                    }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused { commitRename() } // 点别处失焦即提交
                    }
            } else {
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .frame(maxWidth: 180)
            }
            if paneCount > 1 {
                Text("\(paneCount)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .help("\(paneCount) 个分屏")
            }
            // 只在选中/悬停时占位:隐形关闭钮(opacity 0)会撑宽未选中 chip,
            // 字面间距被拉到 chip 内部间距的 6 倍,整条看着疏密失衡。
            // 这里只占位不承载按钮:真按钮压在事件层之上(见下方 overlay),
            // 否则 ChipMouseLayer 会吞掉它的点击
            if isHovering || isSelected {
                Color.clear
                    .frame(width: 18, height: 18)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        // 比轨道的沟(2pt)略收:chip 自己不顶满,整条不显臃肿
        .padding(.vertical, 5.5)
        // 短标题(zsh)的 chip 会缩成一小粒,不好点(issue #9 两轮反馈嫌小):
        // 兜一个最小宽度,内容自然居中,长标题不受影响
        .frame(minWidth: 130)
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
        // 事件层(AppKit)承接按下选中/连击改名/拖动重排,并掐断标题栏拖窗;
        // 改名中撤掉把点击还给 TextField;× 可见时尾部让位,不与按钮争命中
        .overlay {
            if !tab.isRenaming {
                ChipMouseLayer(
                    onPress: select,
                    onDoubleClick: { tab.isRenaming = true },
                    onDragChanged: dragChanged,
                    onDragEnded: dragEnded
                )
                .padding(.trailing, (isHovering || isSelected) ? 30 : 0)
            }
        }
        // 关闭钮独立于事件层:点 × 只关不选,与旧行为一致
        .overlay(alignment: .trailing) {
            if isHovering || isSelected {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        // 命中区比字形大一圈:点偏一点不该变成「选中标签」
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .opacity(0.7)
                .transition(.opacity)
                .padding(.trailing, 12)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

/// chip 的 AppKit 事件层。SwiftUI 手势在 macOS 15 的标题栏里抢不过窗口拖动
/// (拖窗机制在手势判定前就接管,v1.24 的 DragGesture 方案只在 26 生效,issue #9),
/// 用真 NSView 占有事件流一劳永逸:mouseDownCanMoveWindow=false 掐断拖窗,
/// 按下即选中(原生标签手感,也绕开旧系统上单击等待双击判定的迟滞),
/// 连击改名,拖动上报 ΔX 由父级重排。右键不拦,沿响应链上浮给 .contextMenu
private struct ChipMouseLayer: NSViewRepresentable {
    let onPress: () -> Void
    let onDoubleClick: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> MouseView {
        let view = MouseView()
        update(view)
        return view
    }

    func updateNSView(_ view: MouseView, context: Context) {
        update(view)
    }

    private func update(_ view: MouseView) {
        view.onPress = onPress
        view.onDoubleClick = onDoubleClick
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
    }

    final class MouseView: NSView {
        var onPress: (() -> Void)?
        var onDoubleClick: (() -> Void)?
        var onDragChanged: ((CGFloat) -> Void)?
        var onDragEnded: (() -> Void)?
        private var downX: CGFloat = 0
        private var dragging = false

        override var mouseDownCanMoveWindow: Bool { false }
        /// 后台窗口点标签一击即选(原生标签栏行为),不用先点一下激活窗口
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// 自己不出菜单:返回 nil 让右键沿响应链交给 SwiftUI 的 .contextMenu
        override func menu(for event: NSEvent) -> NSMenu? { nil }

        override func mouseDown(with event: NSEvent) {
            downX = event.locationInWindow.x
            dragging = false
            if event.clickCount == 2 {
                onDoubleClick?()
            } else {
                onPress?()  // 首击已选中,连击改名正好落在已选中的标签上
            }
        }

        override func mouseDragged(with event: NSEvent) {
            let delta = event.locationInWindow.x - downX
            // 与旧 DragGesture 的 minimumDistance=4 对齐,点按时的手抖不触发重排
            if !dragging, abs(delta) < 4 { return }
            dragging = true
            onDragChanged?(delta)
        }

        override func mouseUp(with event: NSEvent) {
            if dragging { onDragEnded?() }
            dragging = false
        }
    }
}

/// 单个会话面板:终端 + ⌘F 搜索条覆盖层
struct TerminalPaneView: View {
    @Bindable var session: TerminalSession
    @Environment(SessionManager.self) private var sessionManager

    @State private var searchModel = TerminalSearchModel()
    @State private var isSearchActive = false
    /// 选中即复制的 toast 显隐(自动隐藏任务可被下一次复制续期)
    @State private var copyToastVisible = false
    @State private var copyToastHide: Task<Void, Never>?

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
        .overlay(alignment: .bottom) {
            if copyToastVisible {
                Label("已复制", systemImage: "doc.on.doc")
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.regularMaterial))
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: session.copyToast) { _, stamp in
            guard stamp != nil else { return }
            withAnimation(.easeOut(duration: 0.15)) { copyToastVisible = true }
            copyToastHide?.cancel()
            copyToastHide = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { copyToastVisible = false }
            }
        }
        .onChange(of: sessionManager.searchRequestToken) { _, _ in
            // 只有当前选中会话响应 ⌘F
            guard session.id == sessionManager.selectedID else { return }
            searchModel.terminalView = session.terminalView
            searchModel.activate()
            isSearchActive = true
        }
    }
}
