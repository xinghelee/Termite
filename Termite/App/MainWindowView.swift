import SwiftUI

/// 主窗口:终端区(标签 + 分屏)+ ⌘P 命令面板覆盖层。
/// 每个窗口一个 SessionManager,按 windowKey 从注册表幂等获取 ——
/// SwiftUI 重建窗口内容视图时拿回同一实例,不产生幽灵 manager/多余 shell。
struct MainWindowView: View {
    let windowKey: UUID

    @State private var theme = ThemeStore.shared
    @State private var sidebarVisibility = NavigationSplitViewVisibility.automatic

    private var manager: SessionManager {
        SessionManagerRegistry.shared.manager(for: windowKey)
    }

    var body: some View {
        content(manager)
            .task {
                theme.applyWindowChrome()
                manager.restoreOrCreateInitialTabs()
            }
    }

    private func content(_ manager: SessionManager) -> some View {
        ZStack {
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
            } detail: {
                TerminalTabsView()
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
        }
        .environment(manager)
        .tint(theme.current.accentColor)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: manager.palette.isPresented)
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
