import SwiftUI

/// 主界面:iPhone 栈式 / iPad 双栏。
/// 列表即仪表盘:「等待输入」置顶高亮(手机端的核心时刻),
/// 其余按项目分组(对齐 Mac 侧边栏),工作空间做芯片筛选。
struct MainView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.scenePhase) private var scenePhase
    let client: RemoteClient

    @State private var stackPath: [RemoteSessionSummary] = []
    @State private var splitSelection: RemoteSessionSummary?
    @State private var spaceFilter: String?
    @State private var showSettings = false
    @State private var showPairing = false

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
        .task(id: ObjectIdentifier(client)) {
            while !Task.isCancelled {
                client.requestList()
                try? await Task.sleep(for: .seconds(3))
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
        List {
            if !spaces.isEmpty { spaceChips }
            if !attentionSessions.isEmpty {
                Section {
                    ForEach(attentionSessions) { session in
                        row(session, highlighted: true)
                    }
                } header: {
                    Label("等待你", systemImage: "bell.badge.fill")
                        .foregroundStyle(.orange)
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.sessions) { session in
                        row(session, highlighted: false)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(group.color ?? Color(.systemGray3))
                            .frame(width: 7, height: 7)
                        Text(group.title)
                    }
                }
            }
            if visibleSessions.isEmpty {
                ContentUnavailableView {
                    Label("没有打开的会话", systemImage: "terminal")
                } description: {
                    Text(client.phase == .connected
                         ? "在 Mac 上开个终端标签就会出现在这里"
                         : "正在连接 \(store.selected?.name ?? "")…")
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { client.requestList() }
        .navigationTitle(store.selected?.name ?? "Termite")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { statusPill }
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .overlay {
            if client.phase == .denied { deniedView }
        }
    }

    private func row(_ session: RemoteSessionSummary, highlighted: Bool) -> some View {
        Button {
            open(session)
        } label: {
            HStack(spacing: 12) {
                if highlighted {
                    Image(systemName: session.attention == "input" ? "bell.fill" : "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                } else {
                    Circle()
                        .fill(badgeColor(session))
                        .frame(width: 9, height: 9)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(session.cwd ?? session.shell)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if session.id == lastSessionID {
                    Text("上次")
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(.systemGray5)))
                        .foregroundStyle(.secondary)
                }
                if session.alive {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!session.alive)
        .listRowBackground(highlighted ? Color.orange.opacity(0.12) : Color(.secondarySystemGroupedBackground))
    }

    private var spaceChips: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(nil, title: String(localized: "全部"))
                    ForEach(spaces, id: \.self) { space in
                        chip(space, title: space)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            .listRowBackground(Color.clear)
        }
    }

    private func chip(_ value: String?, title: String) -> some View {
        let selected = spaceFilter == value
        return Button {
            spaceFilter = value
        } label: {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? Color.accentColor : Color(.secondarySystemGroupedBackground)))
                .foregroundStyle(selected ? Color.white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(client.phase == .connected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(client.phase == .connected ? "已连接" : "连接中")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
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
            Image(systemName: "ellipsis.circle")
        }
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

    private func badgeColor(_ session: RemoteSessionSummary) -> Color {
        if !session.alive { return .red }
        if session.running { return .green }
        return Color(.systemGray4)
    }

    // MARK: - 动作

    private func open(_ session: RemoteSessionSummary) {
        if hSize == .regular {
            splitSelection = session
        } else {
            stackPath = [session]
        }
    }

    private func switchMac(_ mac: SavedMac) {
        guard mac.id != store.selected?.id else { return }
        store.selectedID = mac.id
        splitSelection = nil
        stackPath = []
        client.shutdown()
        if let endpoint = store.endpoint(for: mac) {
            client.configure(endpoint)
        }
    }
}
