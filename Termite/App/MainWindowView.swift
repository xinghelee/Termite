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

    private func content(_ manager: SessionManager) -> some View {
        ZStack {
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
                    // 系统自带的侧边栏切换按钮是大号玻璃样式,和标题栏其余小圆钮不搭;
                    // 移除后由 TerminalTabsView 用统一样式的 PanelIconButton 替代
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                TerminalTabsView(toggleSidebar: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
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
        .tint(theme.current.accentColor)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: manager.palette.isPresented)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: manager.directoryJumper.isPresented)
        .background(WindowConfigurator(
            appearanceName: theme.current.appearanceName,
            backgroundColor: theme.current.backgroundNSColor,
            onWindow: { window in
                SessionManagerRegistry.shared.bind(manager, to: window)
            }
        ))
        .frame(minWidth: 640, minHeight: 420)
    }
}
