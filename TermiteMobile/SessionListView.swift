import SwiftUI

/// 主界面:iPhone 栈式 / iPad 双栏。
/// 列表即仪表盘:「等待输入」置顶高亮(手机端的核心时刻),
/// 其余按项目分组(对齐 Mac 侧边栏),工作空间做芯片筛选。
/// 底部 TabBar:终端 / 对话。两个 tab 各有自己的会话列表 ——
/// 对话 tab 只列有 agent 转录的会话,普通 shell 归终端 tab。
/// TabBar 只活在列表层:push 进会话页时自动隐藏,把底部让给按键条/输入框
struct MainView: View {
    let client: RemoteClient
    @State private var chatClient = ChatClient()
    /// 模拟器 tab 和终端页里的浮窗共用一个客户端:同一时刻只该有一条镜像流
    @State private var mirrorClient = MirrorClient()
    /// 三个 tab 共用一套配色:主题由终端连接下发,存这儿再注进环境
    @State private var themeStore = ThemeStore()

    var body: some View {
        // 用经典 .tabItem 而不是 iOS 18 的 Tab —— target 是 iOS 17
        TabView {
            TerminalTab(client: client)
                .tabItem { Label("终端", systemImage: "terminal") }
            ChatSessionListView(client: chatClient)
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
            SimulatorTabView(client: mirrorClient)
                .tabItem { Label("模拟器", systemImage: "iphone.gen3") }
        }
        .environment(\.termiteTheme, themeStore.theme)
        .tint(themeStore.theme.accent)
        .onChange(of: client.theme, initial: true) { _, palette in
            themeStore.palette = palette
        }
    }
}

private struct TerminalTab: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.termiteTheme) private var theme
    let client: RemoteClient

    @AppStorage(MobileSettingsKeys.bellHaptics) private var bellHaptics = true
    @State private var stackPath: [RemoteSessionSummary] = []
    @State private var splitSelection: RemoteSessionSummary?
    @State private var spaceFilter: String?
    /// 会话搜索:20 来个会话 + 同名项目(xc-sport-ios 就三个),手机屏上翻找最费劲
    @State private var query = ""
    @State private var openedForward: RemoteForwardSummary?
    @State private var showSettings = false
    @State private var showPairing = false
    @State private var connectionPulse = false
    @State private var launchingProjectID: UUID?
    @State private var projectError: String?

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
        .alert("无法启动项目", isPresented: Binding(
            get: { projectError != nil },
            set: { if !$0 { projectError = nil } }
        )) {
            Button("好", role: .cancel) { projectError = nil }
        } message: {
            Text(projectError ?? "")
        }
        .onAppear {
            client.onProjectOpened = { session in
                launchingProjectID = nil
                open(session)
            }
            client.onProjectOpenFailed = { message in
                launchingProjectID = nil
                projectError = message
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { client.kickReconnect() }
        }
        .onChange(of: spaceOptions.map(\.id)) { _, newSpaces in
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
                if !spaceOptions.isEmpty {
                    spaceSelector
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                }
                if !client.forwards.isEmpty, query.isEmpty {
                    forwardsSection
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                }
                if !attentionSessions.isEmpty {
                    sessionSection(
                        title: String(localized: "等待你"),
                        symbol: "bell.badge.fill",
                        color: .orange,
                        sessions: attentionSessions,
                        count: attentionSessions.count,
                        projectID: nil,
                        projectPath: nil,
                        highlighted: true
                    )
                }
                ForEach(groups) { group in
                    sessionSection(
                        title: group.title,
                        color: group.color ?? Color(.systemGray3),
                        sessions: group.sessions,
                        count: group.sessionCount,
                        projectID: group.projectID,
                        projectPath: group.projectPath,
                        highlighted: false
                    )
                }
                if visibleSessions.isEmpty {
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
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
            }
            .padding(.bottom, 28)
        }
        .background(sidebarBackground.ignoresSafeArea())
        .refreshable { client.requestList() }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: Text("搜索会话、项目、路径"))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
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
        .sheet(item: $openedForward) { forward in
            if let mac = store.selected, let endpoint = store.endpoint(for: mac) {
                ForwardWebView(forward: forward, host: endpoint.host, token: endpoint.token)
            }
        }
    }

    /// Mac 转发出来的本机服务:模拟器里的调试 console、dev server 之类,
    /// 点进去是内置浏览器 —— 手机上看 App 界面并操作就靠这条
    private var forwardsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("本机服务")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(client.forwards) { forward in
                Button {
                    openedForward = forward
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "globe")
                            .font(.system(size: 13))
                            .foregroundStyle(sidebarAccent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(forward.label)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.primary)
                            // verbatim:端口号插 Int 会被格式化成「8,099」
                            Text(verbatim: "localhost:\(forward.target)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(sidebarSurface))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sessionSection(
        title: String,
        symbol: String? = nil,
        color: Color,
        sessions: [RemoteSessionSummary],
        count: Int,
        projectID: UUID?,
        projectPath: String?,
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
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)

            ForEach(sessions) { session in
                row(session, highlighted: highlighted)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if sessions.isEmpty, count == 0, let projectID, let projectPath {
                defaultTerminalRow(projectID: projectID, title: title, projectPath: projectPath)
            } else if sessions.isEmpty, !highlighted {
                Text(count == 0 ? "暂无打开的会话" : "会话已置顶到等待你")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 16)
                    .frame(minHeight: 24)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }

    private func defaultTerminalRow(projectID: UUID, title: String, projectPath: String) -> some View {
        let launching = launchingProjectID == projectID
        return Button {
            guard !launching else { return }
            launchingProjectID = projectID
            client.openProject(projectID)
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(Color(.systemGray4).opacity(0.12))
                    Circle()
                        .fill(Color(.systemGray4))
                        .frame(width: 8, height: 8)
                }
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text((projectPath as NSString).abbreviatingWithTildeInPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if launching {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 58)
            .background(sidebarSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(SessionRowButtonStyle())
        .disabled(launching)
        .accessibilityLabel("启动 \(title)")
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

    /// 筛选条本体在 SpaceFilterBar(和对话 tab 共用同一个组件)
    private var spaceSelector: some View {
        SpaceFilterBar(
            options: spaceOptions.map { .init(id: $0.id, title: $0.title) },
            selection: $spaceFilter,
            theme: theme
        )
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
                .foregroundStyle(.primary)
                .background(sidebarSurface, in: Circle())
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

    private struct SpaceOption: Identifiable {
        let id: String
        let serverID: UUID?
        let title: String
    }

    /// 新服务端下发完整目录；旧服务端仍从有会话的工作区名称回退生成。
    private var spaceOptions: [SpaceOption] {
        if !client.sidebarSpaces.isEmpty {
            return client.sidebarSpaces.map {
                SpaceOption(id: $0.id.uuidString, serverID: $0.id, title: $0.name)
            }
        }
        var seen = Set<String>()
        return client.sessions.compactMap { session in
            guard let space = session.space, !seen.contains(space) else { return nil }
            seen.insert(space)
            return SpaceOption(id: "legacy:\(space)", serverID: nil, title: space)
        }
    }

    /// 空间筛选:未分组会话全空间可见(对齐 Mac 侧边栏语义)
    private var visibleSessions: [RemoteSessionSummary] {
        matchingQuery(spaceFiltered)
    }

    private var spaceFiltered: [RemoteSessionSummary] {
        guard let spaceFilter,
              let option = spaceOptions.first(where: { $0.id == spaceFilter }) else {
            return client.sessions
        }
        if let serverID = option.serverID {
            return client.sessions.filter {
                $0.spaceID == serverID || $0.projectPath == nil
            }
        }
        return client.sessions.filter { $0.space == option.title || $0.space == nil }
    }

    /// 搜索:标题 / 项目 / 路径 / shell / 工作空间都算命中,大小写不敏感。
    /// 会话标题常带 ✳ ◑ 这类状态符号,所以只做包含匹配、不做前缀匹配
    private func matchingQuery(_ sessions: [RemoteSessionSummary]) -> [RemoteSessionSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return sessions }
        return sessions.filter { session in
            let fields = [session.title, session.project, session.projectPath,
                          session.cwd, session.shell, session.space]
            return fields.contains { $0?.lowercased().contains(needle) == true }
        }
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
        let projectID: UUID?
        let projectPath: String?
        var sessions: [RemoteSessionSummary]
        var sessionCount: Int
    }

    /// 优先按 Mac 下发的完整项目目录建组，空项目也保留；旧服务端再从会话反推。
    private var groups: [SessionGroup] {
        var order: [String] = []
        var byKey: [String: SessionGroup] = [:]

        let selectedSpaceID = spaceFilter.flatMap { key in
            spaceOptions.first(where: { $0.id == key })?.serverID
        }
        let catalog = client.sidebarProjects.filter { project in
            selectedSpaceID == nil || project.spaceID == selectedSpaceID
        }
        for project in catalog {
            let projectSessions = visibleSessions.filter { $0.projectPath == project.path }
            let rows = projectSessions.filter { $0.attention == nil || !$0.alive }
            order.append(project.path)
            byKey[project.path] = SessionGroup(
                id: project.path,
                title: project.name,
                color: project.accent.map { Color(UIColor(hex: $0)) },
                projectID: project.id,
                projectPath: project.path,
                sessions: rows,
                sessionCount: projectSessions.count
            )
        }
        let catalogPaths = Set(catalog.map(\.path))

        for session in visibleSessions where session.attention == nil || !session.alive {
            if let projectPath = session.projectPath, catalogPaths.contains(projectPath) {
                continue
            }
            let key = session.projectPath ?? "•ungrouped•\(session.window ?? 0)"
            if byKey[key] == nil {
                order.append(key)
                let color = session.projectColor.map { Color(UIColor(hex: $0)) }
                byKey[key] = SessionGroup(
                    id: key,
                    title: session.project ?? String(localized: "未分组"),
                    color: color,
                    projectID: nil,
                    projectPath: session.projectPath,
                    sessions: [],
                    sessionCount: 0
                )
            }
            byKey[key]?.sessions.append(session)
            byKey[key]?.sessionCount += 1
        }
        let all = order.compactMap { byKey[$0] }
        // 搜索时空项目组是噪音(平时留着是为了能从手机开空项目)
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.filter { !$0.sessions.isEmpty }
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
        return .green
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
