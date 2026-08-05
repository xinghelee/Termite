import SwiftUI

/// 主界面:iPhone 栈式 / iPad 双栏。
/// 列表即仪表盘:「等待输入」置顶高亮(手机端的核心时刻),
/// 其余按项目分组(对齐 Mac 侧边栏),工作空间做芯片筛选。
struct MainView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let client: RemoteClient

    @AppStorage(MobileSettingsKeys.bellHaptics) private var bellHaptics = true
    @State private var stackPath: [RemoteSessionSummary] = []
    @State private var splitSelection: RemoteSessionSummary?
    @State private var spaceFilter: String?
    @State private var showSettings = false
    @State private var showPairing = false
    @State private var connectionPulse = false

    var body: some View {
        Group {
            if hSize == .regular {
                splitLayout
            } else {
                stackLayout
            }
        }
        .sheet(isPresented: $showSettings) {
            MobileSettingsView(client: client)
        }
        .sheet(isPresented: $showPairing) {
            PairingView(isSheet: true)
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { client.kickReconnect() }
        }
        .onChange(of: spaces) { _, newSpaces in
            if let spaceFilter, !newSpaces.contains(spaceFilter) {
                self.spaceFilter = nil
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: attentionSessionIDs)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: client.theme)
        .sensoryFeedback(.warning, trigger: attentionSessionIDs) { oldIDs, newIDs in
            bellHaptics && !newIDs.subtracting(oldIDs).isEmpty
        }
        .task(id: ObjectIdentifier(client)) {
            while !Task.isCancelled {
                client.requestList()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .task(id: client.phase) {
            connectionPulse = false
            guard client.phase == .connecting, !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 1.15).repeatForever(autoreverses: false)) {
                connectionPulse = true
            }
        }
    }

    private var stackLayout: some View {
        NavigationStack(path: $stackPath) {
            listCore
                .navigationDestination(for: RemoteSessionSummary.self) { session in
                    TerminalScreenView(client: client, session: session)
                }
        }
    }

    private var splitLayout: some View {
        NavigationSplitView {
            listCore
                .navigationSplitViewColumnWidth(min: 300, ideal: 340)
        } detail: {
            if let session = splitSelection {
                TerminalScreenView(client: client, session: session)
                    .id(session.id) // 换会话必换视图:附着生命周期跟着走
            } else {
                ContentUnavailableView("选一个会话", systemImage: "terminal",
                                       description: Text("左侧点开任意终端"))
            }
        }
    }

    // MARK: - 列表

    private var listCore: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !spaces.isEmpty {
                    spaceSelector
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                }
                if !attentionSessions.isEmpty {
                    sessionSection(
                        title: String(localized: "等待你"),
                        symbol: "bell.badge.fill",
                        color: .orange,
                        sessions: attentionSessions,
                        highlighted: true
                    )
                }
                ForEach(groups) { group in
                    sessionSection(
                        title: group.title,
                        color: group.color ?? Color(.systemGray3),
                        sessions: group.sessions,
                        highlighted: false
                    )
                }
                if visibleSessions.isEmpty {
                    ContentUnavailableView {
                        Label("没有打开的会话", systemImage: "terminal")
                    } description: {
                        Text(client.phase == .connected
                             ? "在 Mac 上开个终端标签就会出现在这里"
                             : "正在连接 \(store.selected?.name ?? "")…")
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 28)
        }
        .background(sidebarBackground.ignoresSafeArea())
        .refreshable { client.requestList() }
        .navigationTitle(store.selected?.name ?? "Termite")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { connectionMark }
            ToolbarItem(placement: .principal) { machineTitle }
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .toolbarBackground(sidebarBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(sidebarColorScheme, for: .navigationBar)
        .environment(\.colorScheme, sidebarColorScheme)
        .overlay {
            if client.phase == .denied { deniedView }
        }
    }

    private func sessionSection(
        title: String,
        symbol: String? = nil,
        color: Color,
        sessions: [RemoteSessionSummary],
        highlighted: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                        .symbolEffect(.bounce, value: attentionSessionIDs)
                } else {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(highlighted ? color : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(sessions.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)

            ForEach(sessions) { session in
                row(session, highlighted: highlighted)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }

    private func row(_ session: RemoteSessionSummary, highlighted: Bool) -> some View {
        Button {
            open(session)
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill((highlighted ? Color.orange : badgeColor(session)).opacity(0.14))
                    if highlighted {
                        Image(systemName: session.attention == "input" ? "bell.fill" : "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.orange)
                    } else {
                        Circle()
                            .fill(badgeColor(session))
                            .frame(width: 8, height: 8)
                    }
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if highlighted, let wait = waitDescription(session) {
                        Text(wait)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else {
                        Text(session.cwd ?? session.shell)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                if session.id == lastSessionID {
                    Text("上次")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(.secondary)
                }
                if session.alive {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 64)
            .background(rowBackground(session, highlighted: highlighted))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if isSelected(session) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(sidebarAccent.opacity(0.72), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SessionRowButtonStyle())
        .disabled(!session.alive)
        .opacity(session.alive ? 1 : 0.55)
        .accessibilityHint(session.alive ? Text("打开终端") : Text("会话已结束"))
    }

    @ViewBuilder
    private var spaceSelector: some View {
        if spaces.count <= 3 {
            HStack(spacing: 2) {
                segmentButton(nil, title: String(localized: "全部"))
                ForEach(spaces, id: \.self) { space in
                    segmentButton(space, title: space)
                }
            }
            .padding(2)
            .background(sidebarSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterButton(nil, title: String(localized: "全部"))
                    ForEach(spaces, id: \.self) { space in
                        filterButton(space, title: space)
                    }
                }
            }
        }
    }

    private func segmentButton(_ value: String?, title: String) -> some View {
        let selected = spaceFilter == value
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                spaceFilter = value
            }
        } label: {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(
                    selected ? sidebarAccent : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .foregroundStyle(selected ? sidebarAccentForeground : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func filterButton(_ value: String?, title: String) -> some View {
        let selected = spaceFilter == value
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                spaceFilter = value
            }
        } label: {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(
                    selected ? sidebarAccent : sidebarSurface,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .foregroundStyle(selected ? sidebarAccentForeground : .primary)
        }
        .buttonStyle(.plain)
    }

    private var machineTitle: some View {
        VStack(spacing: 1) {
            Text(store.selected?.name ?? "Termite")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(phaseTitle)
                Text("·")
                Text("\(client.sessions.count) 个会话")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var connectionMark: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(sidebarSurface, in: Circle())
            ZStack {
                if client.phase == .connecting {
                    Circle()
                        .stroke(phaseColor.opacity(0.55), lineWidth: 1.5)
                        .frame(width: 9, height: 9)
                        .scaleEffect(connectionPulse ? 2.2 : 1)
                        .opacity(connectionPulse ? 0 : 0.9)
                }
                Circle()
                    .fill(phaseColor)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            }
        }
        .accessibilityLabel(Text(phaseTitle))
    }

    private var menu: some View {
        Menu {
            if store.macs.count > 1 {
                Section("我的 Mac") {
                    ForEach(store.macs) { mac in
                        Button {
                            switchMac(mac)
                        } label: {
                            if mac.id == store.selected?.id {
                                Label(mac.name, systemImage: "checkmark")
                            } else {
                                Text(mac.name)
                            }
                        }
                    }
                }
            }
            Button("添加 Mac", systemImage: "plus.circle") { showPairing = true }
            Button("设置", systemImage: "gearshape") { showSettings = true }
            Button("刷新", systemImage: "arrow.clockwise") { client.requestList() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .frame(width: 32, height: 32)
                .foregroundStyle(sidebarAccent)
                .background(sidebarAccent.opacity(0.14), in: Circle())
        }
        .accessibilityLabel("更多")
    }

    private var deniedView: some View {
        ContentUnavailableView {
            Label("配对已失效", systemImage: "key.slash")
        } description: {
            Text("Mac 端重新生成过密钥,请重新扫码配对")
        } actions: {
            Button("重新配对") { showPairing = true }
                .buttonStyle(.borderedProminent)
        }
        .background(.regularMaterial)
    }

    // MARK: - 数据切片

    private var spaces: [String] {
        var seen = Set<String>()
        return client.sessions.compactMap { session in
            guard let space = session.space, !seen.contains(space) else { return nil }
            seen.insert(space)
            return space
        }
    }

    /// 空间筛选:未分组会话全空间可见(对齐 Mac 侧边栏语义)
    private var visibleSessions: [RemoteSessionSummary] {
        guard let spaceFilter else { return client.sessions }
        return client.sessions.filter { $0.space == spaceFilter || $0.space == nil }
    }

    private var attentionSessions: [RemoteSessionSummary] {
        visibleSessions.filter { $0.attention != nil && $0.alive }
    }

    private var attentionSessionIDs: Set<UUID> {
        Set(attentionSessions.map(\.id))
    }

    private struct SessionGroup: Identifiable {
        let id: String
        let title: String
        let color: Color?
        var sessions: [RemoteSessionSummary]
    }

    /// 按项目分组,保持服务端(侧边栏)顺序;注意力会话已单列,不重复出现
    private var groups: [SessionGroup] {
        var order: [String] = []
        var byKey: [String: SessionGroup] = [:]
        for session in visibleSessions where session.attention == nil || !session.alive {
            let key = session.projectPath ?? "•ungrouped•\(session.window ?? 0)"
            if byKey[key] == nil {
                order.append(key)
                let color = session.projectColor.map { Color(UIColor(hex: $0)) }
                byKey[key] = SessionGroup(
                    id: key,
                    title: session.project ?? String(localized: "未分组"),
                    color: color,
                    sessions: []
                )
            }
            byKey[key]?.sessions.append(session)
        }
        return order.compactMap { byKey[$0] }
    }

    private var lastSessionID: UUID? {
        store.selected.flatMap { store.lastSession(of: $0) }
    }

    // 会话列表与终端使用同一套远端主题，保证 iPhone 页面切换和 iPad 分栏都连续。
    private var usesTerminalTheme: Bool {
        client.theme != nil
    }

    private var sidebarThemeIsDark: Bool {
        usesTerminalTheme ? (client.theme?.isDark ?? true) : true
    }

    private var sidebarColorScheme: ColorScheme {
        sidebarThemeIsDark ? .dark : .light
    }

    private var sidebarBackground: Color {
        guard usesTerminalTheme, let theme = client.theme else {
            return Color(.systemGroupedBackground)
        }
        return Color(UIColor(hex: theme.background))
    }

    private var sidebarSurface: Color {
        guard usesTerminalTheme else {
            return Color(.secondarySystemGroupedBackground)
        }
        return sidebarThemeIsDark ? Color.white.opacity(0.075) : Color.black.opacity(0.055)
    }

    private var sidebarAccent: Color {
        guard usesTerminalTheme, let theme = client.theme else {
            return Color(red: 0.91, green: 0.64, blue: 0.24)
        }
        return Color(UIColor(hex: theme.accent))
    }

    private var sidebarAccentForeground: Color {
        guard usesTerminalTheme, let hex = client.theme?.accent else { return .black }
        let color = UIColor(hex: hex)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        let luminance = red * 0.299 + green * 0.587 + blue * 0.114
        return luminance > 0.58 ? .black : .white
    }

    private var phaseTitle: String {
        client.phase == .connected ? String(localized: "已连接") : String(localized: "连接中")
    }

    private var phaseColor: Color {
        switch client.phase {
        case .connected: .green
        case .idle: Color(.systemGray3)
        case .connecting, .denied: .orange
        }
    }

    private func isSelected(_ session: RemoteSessionSummary) -> Bool {
        hSize == .regular && splitSelection?.id == session.id
    }

    private func rowBackground(_ session: RemoteSessionSummary, highlighted: Bool) -> Color {
        if isSelected(session) { return sidebarAccent.opacity(0.16) }
        if highlighted { return Color.orange.opacity(0.11) }
        return sidebarSurface
    }

    private func badgeColor(_ session: RemoteSessionSummary) -> Color {
        if !session.alive { return .red }
        if session.running { return .green }
        return Color(.systemGray4)
    }

    /// 「等待你」行副标题:等了多久(分钟粒度,刚进入不显示秒)
    private func waitDescription(_ session: RemoteSessionSummary) -> String? {
        guard let seconds = session.attentionSeconds else {
            return session.attention == "input" ? String(localized: "等待输入") : String(localized: "命令已完成")
        }
        let base = session.attention == "input"
            ? String(localized: "等待输入") : String(localized: "命令已完成")
        if seconds < 60 { return base }
        if seconds < 3600 { return base + " · " + String(localized: "已等待 \(seconds / 60) 分钟") }
        return base + " · " + String(localized: "已等待 \(seconds / 3600) 小时")
    }

    // MARK: - 动作

    private func open(_ session: RemoteSessionSummary) {
        if hSize == .regular {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                splitSelection = session
            }
        } else {
            stackPath = [session]
        }
    }

    private func switchMac(_ mac: SavedMac) {
        guard mac.id != store.selected?.id else { return }
        store.selectedID = mac.id
        splitSelection = nil
        stackPath = []
        spaceFilter = nil
        client.shutdown()
        if let endpoint = store.endpoint(for: mac) {
            client.configure(endpoint)
        }
    }
}

private struct SessionRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
