import SwiftUI

/// 右侧检查器抽屉(Xcode inspector 式,与 Berth 的 InspectorRail 同一套语言):
/// 标题栏一个开关整体展开/收起,抽屉顶部一排图标分段选面板,互斥单开。
/// 各面板沿用自己的宽度与左缘拖拽调宽(Git / 文件浏览器各自记住宽度)
struct InspectorDrawer: View {
    let session: TerminalSession
    let panel: SessionManager.SidePanel
    @Environment(SessionManager.self) private var sessionManager

    @Namespace private var segmentNamespace
    /// 抽屉统一宽度(左缘拖拽调整,持久化):切换面板时不再跳宽
    @AppStorage("inspector.width") private var storedWidth = 330.0
    @State private var dragStartWidth: Double?
    /// 面板临时要求的最小宽度(Git diff / 文件预览 520pt)
    @State private var contentMinWidth: CGFloat = 0

    static let minWidth: Double = 260
    static let maxWidth: Double = 980

    private var theme: TerminalTheme { ThemeStore.shared.current }

    private struct DrawerTab: Identifiable {
        let panel: SessionManager.SidePanel
        let symbol: String
        let help: String
        var id: String { panel.rawValue }
    }

    private var tabs: [DrawerTab] {
        [
            DrawerTab(panel: .timeline, symbol: "clock.arrow.circlepath", help: String(localized: "命令时间线(⌘I)")),
            DrawerTab(panel: .git, symbol: "arrow.trianglehead.branch", help: String(localized: "Git 面板(⌘G)")),
            DrawerTab(panel: .files, symbol: "folder", help: String(localized: "文件浏览器(⇧⌘E)")),
            DrawerTab(panel: .theme, symbol: "paintpalette", help: String(localized: "终端配色")),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider().overlay(theme.borderColor)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: max(CGFloat(storedWidth), contentMinWidth))
        .background(theme.panelBackground)
        .onPreferenceChange(InspectorMinWidthKey.self) { contentMinWidth = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: contentMinWidth)
        // 左缘拖拽调宽,双击复位
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.clear)
                .frame(width: 7)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .onTapGesture(count: 2) { storedWidth = 330 }
                .gesture(
                    // 全局坐标系:局部坐标会随面板变宽而移动原点,形成抖动反馈循环
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if dragStartWidth == nil { dragStartWidth = storedWidth }
                            let proposed = (dragStartWidth ?? 330) - Double(value.translation.width)
                            storedWidth = min(max(proposed, Self.minWidth), Self.maxWidth)
                        }
                        .onEnded { _ in dragStartWidth = nil }
                )
        }
    }

    /// Xcode 26 式分段胶囊:整条是一个胶囊容器,选中段是浮起小胶囊(切换时滑动跟随)。
    /// 收起不在这里 —— 走标题栏开关(与 Xcode 一致)
    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                tabButton(tab)
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(theme.elevatedBackground)
                .overlay(Capsule().stroke(theme.borderColor, lineWidth: 1))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func tabButton(_ tab: DrawerTab) -> some View {
        let isActive = panel == tab.panel
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                sessionManager.activeSidePanel = tab.panel
            }
        } label: {
            Image(systemName: tab.symbol)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 24)
                .background {
                    if isActive {
                        RaisedCapsule()
                            .matchedGeometryEffect(id: "drawer-segment", in: segmentNamespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tab.help)
        .accessibilityLabel(tab.help)
    }

    @ViewBuilder
    private var content: some View {
        switch panel {
        case .timeline:
            CommandTimelineView(session: session) { close() }
                .id(session.id)
        case .git:
            GitPanelView(session: session) { close() }
                .id(session.id)
        case .files:
            FileBrowserView(session: session) { close() }
                .id(session.id)
        case .theme:
            VStack(spacing: 0) {
                ThemePanelView()
                Spacer(minLength: 0)
            }
            // 配色色卡固定 312pt 宽,抽屉被拖得更窄时撑住,不裁切
            .preference(key: InspectorMinWidthKey.self, value: 312)
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            sessionManager.activeSidePanel = nil
        }
    }
}

/// 抽屉开关(Xcode 式,标题栏右侧):单个按钮整体展开/收起。
/// 外观与按钮组里其他图标钮一致(24pt、悬停圆底),图标为镜像的 sidebar
struct InspectorToggleButton: View {
    let isOpen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOpen ? Color.primary : Color.secondary)
                // 水平镜像:面板线条移到右侧,对应右侧抽屉
                .scaleEffect(x: -1, y: 1)
                .frame(width: 24, height: 24)
                // 只给悬停底:外层按钮组已有一块胶囊底,再自带玻璃圆会叠成两层
                .background(Circle().fill(hovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(String(localized: "检查器:时间线 / Git / 文件 / 配色"))
        .accessibilityLabel(String(localized: "检查器:时间线 / Git / 文件 / 配色"))
    }
}

/// 抽屉内面板临时要求的最小宽度(取各上报值的最大者)
struct InspectorMinWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
