import AppKit
import SwiftUI

/// 主窗口:终端区(标签 + 分屏)+ ⌘P 命令面板覆盖层。
/// 每个窗口一个 SessionManager,按 windowKey 从注册表幂等获取 ——
/// SwiftUI 重建窗口内容视图时拿回同一实例,不产生幽灵 manager/多余 shell。
struct MainWindowView: View {
    let windowKey: UUID

    @State private var theme = ThemeStore.shared
    @State private var sidebarVisibility = NavigationSplitViewVisibility.automatic
    @Environment(\.openWindow) private var openWindow

    private var manager: SessionManager {
        SessionManagerRegistry.shared.manager(for: windowKey)
    }

    var body: some View {
        content(manager)
            .task {
                theme.applyWindowChrome()
                // 首窗口恢复多窗口存档时,把其余窗口逐个开出来(各自认领挂起状态)
                for key in manager.restoreOrCreateInitialTabs(windowKey: windowKey) {
                    openWindow(id: "main", value: key)
                }
            }
    }

    /// chrome 带透明毛玻璃(默认开;`defaults write` app.translucentChrome 可关)
    private var translucent: Bool { SettingsKeys.translucentChromeOn }

    private func content(_ manager: SessionManager) -> some View {
        // 项目 accent:覆盖本窗口的强调色与标题栏底色,多窗口跑不同项目时一眼分辨
        let projectAccent = ProjectStore.shared.current(for: manager)?.accentHex
        let effectiveTheme = theme.current.withAccent(projectAccent)
        // chrome 带色(标题栏 = 侧边栏,不透明模式的窗口底色)
        let chromeBand = projectAccent.map {
            theme.current.sidebarNSColor.mixed(with: NSColor(hex: $0), ratio: 0.16)
        } ?? theme.current.sidebarNSColor
        // 玻璃 tint 用不压黑的主题背景色:sidebarNSColor 那 35% 黑是给不透明层次用的,
        // 叠在深色玻璃上整条 chrome 就发死黑,透不出桌面(用户反馈「背景太黑」)
        let glassTint = projectAccent.map {
            theme.current.backgroundNSColor.mixed(with: NSColor(hex: $0), ratio: 0.16)
        } ?? theme.current.backgroundNSColor
        return ZStack {
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                // 系统原生切换按钮在 macOS 26 是尺寸不可调的玻璃大圆,与标题栏
                // 其他 24pt 图标不成比例;移除后交给 TerminalTabsView 用同规格
                // 小按钮渲染(位于标题栏最左,收起后位置不变)
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                TerminalTabsView(toggleSidebar: {
                    withAnimation {
                        sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
                    }
                })
            }

            if manager.palette.isPresented {
                Color.black.opacity(0.28) // 点击空白处关闭 + 压暗背景聚焦
                    .contentShape(Rectangle())
                    .onTapGesture { manager.palette.dismiss() }
                VStack {
                    CommandPaletteView()
                        .padding(.top, 90)
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }

            if manager.directoryJumper.isPresented {
                Color.black.opacity(0.28)
                    .contentShape(Rectangle())
                    .onTapGesture { manager.directoryJumper.dismiss() }
                VStack {
                    DirectoryJumperView()
                        .padding(.top, 90)
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }

            if manager.historySearch.isPresented {
                Color.black.opacity(0.28)
                    .contentShape(Rectangle())
                    .onTapGesture { manager.historySearch.dismiss() }
                VStack {
                    HistorySearchView()
                        .padding(.top, 90)
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .environment(manager)
        .sheet(isPresented: Binding(
            get: { manager.dailyReportPresented },
            set: { manager.dailyReportPresented = $0 }
        )) {
            DailyReportView {
                manager.dailyReportPresented = false
            }
        }
        .sheet(isPresented: Binding(
            get: { manager.portsPresented },
            set: { manager.portsPresented = $0 }
        )) {
            PortsView {
                manager.portsPresented = false
            }
        }
        .tint(effectiveTheme.accentColor)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: manager.palette.isPresented)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: manager.directoryJumper.isPresented)
        // 透明 chrome 的底层:整窗毛玻璃 + 半透主题 tint。终端区(chromeBackground)
        // 与侧边栏选中行等都画在其上,只有标题栏与侧边栏空白处真正透出桌面
        .background {
            if translucent {
                ZStack {
                    WindowBackdrop()
                    Color(nsColor: glassTint).opacity(0.45)
                }
                .ignoresSafeArea()
            }
        }
        .background(WindowConfigurator(
            appearanceName: theme.current.appearanceName,
            // 窗口底色即透明标题栏透出的颜色:用 chrome 带色(= 侧边栏色),
            // 顶栏与侧边栏连成一块暗底,终端区自己铺亮底;透明模式下底色清空,
            // 颜色职责移交上面的 tint 层
            backgroundColor: chromeBand,
            translucent: translucent,
            onWindowEarly: { window in
                // 首帧之前把窗口摆到上次的位置(Dock 重开/冷启动都不闪旧位置)
                SessionManagerRegistry.shared.prepareForReveal(manager, window: window)
            },
            onWindow: { window in
                SessionManagerRegistry.shared.bind(manager, to: window)
            }
        ))
        .frame(minWidth: 640, minHeight: 420)
    }
}
