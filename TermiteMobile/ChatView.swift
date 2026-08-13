import SwiftUI

/// 对话 tab 的会话列表:只列有 agent 转录的会话。
/// 普通 shell 归终端 tab —— 这个 tab 的心智是「我的 AI 会话」
struct ChatSessionListView: View {
    let client: ChatClient

    @Environment(ConnectionStore.self) private var store
    @Environment(\.termiteTheme) private var theme
    /// 工作空间筛选:和终端 tab 同一套语义 —— 未分组的会话在所有空间都可见。
    /// 存 uuidString 而不是 UUID,是为了和终端共用 SpaceFilterBar
    @State private var spaceFilter: String?
    @State private var path: [ChatClient.SessionInfo] = []
    @State private var showLaunch = false

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if !client.spaces.isEmpty {
                    SpaceFilterBar(
                        options: client.spaces.map { .init(id: $0.id.uuidString, title: $0.name) },
                        selection: $spaceFilter,
                        theme: theme
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                }
                if client.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("没有 AI 会话", systemImage: "bubble.left.and.text.bubble.right")
                    } description: {
                        Text(client.agents.isEmpty
                             ? "在 Mac 上开一个 agent 会话就会出现在这里"
                             : "点右上角的 + 直接在 Mac 上唤起一个")
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(visibleSessions) { session in
                            NavigationLink(value: session) { row(session) }
                                .termiteRow(theme)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .termiteScreen(theme)
            .navigationTitle("对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleDisplayMode(.inline)
            .refreshable { client.refresh() }
            .toolbar {
                if !client.agents.isEmpty, !client.projects.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showLaunch = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("唤起 agent")
                    }
                }
            }
            .navigationDestination(for: ChatClient.SessionInfo.self) { session in
                ChatView(client: client, session: session)
                    .onAppear { client.attach(session.id) }
                    // 二级页把底部让给输入框
                    .toolbar(.hidden, for: .tabBar)
            }
        }
        .sheet(isPresented: $showLaunch) {
            LaunchAgentSheet(client: client, spaceFilter: spaceFilter)
        }
        .onChange(of: client.launched) { _, launched in
            // Mac 那边新 pane 开好了:关掉选择面板,直接推进对话页
            guard let launched else { return }
            showLaunch = false
            path = [launched]
            client.consumeLaunched()
        }
        .onAppear {
            if let mac = store.selected, let endpoint = store.endpoint(for: mac) {
                client.connect(endpoint)
            }
            client.refresh()
        }
        .task(id: ObjectIdentifier(client)) {
            // 轮询保持 canSend / 等待状态是新的 —— 和终端 tab 同一个节奏
            while !Task.isCancelled {
                client.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// 未分组会话在所有空间可见(对齐 Mac 侧边栏与终端 tab)
    private var visibleSessions: [ChatClient.SessionInfo] {
        guard let spaceFilter else { return client.sessions }
        return client.sessions.filter {
            $0.spaceID?.uuidString == spaceFilter || $0.spaceID == nil
        }
    }

    private func row(_ session: ChatClient.SessionInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text(shortPath(session.cwd) + " · " + session.agent)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            if session.canSend == false {
                Image(systemName: "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if session.attention == "input" {
                // 权限提示这类在转录里看不见,列表先标出来,免得你以为它没动静
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text(relative(session.lastActivity))
                .font(.system(size: 11))
                .foregroundStyle(theme.tertiaryText)
        }
        .padding(.vertical, 2)
    }

    private func shortPath(_ path: String?) -> String {
        guard let path else { return "" }
        return (path as NSString).lastPathComponent
    }

    private func relative(_ time: Double) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Date(timeIntervalSince1970: time), relativeTo: Date())
    }
}

/// 唤起面板:选一家 agent + 一个项目,Mac 就在那个目录开个新 pane 敲下命令。
///
/// 只列 Mac 上真装了的 agent —— 没装的选了也只会得到一句 command not found
private struct LaunchAgentSheet: View {
    let client: ChatClient
    /// 跟随列表当前的工作空间:在「Work」里点 + 就只看到 Work 的项目
    let spaceFilter: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.termiteTheme) private var theme
    @State private var agent: ChatClient.AgentOption?
    @State private var query = ""

    private var projects: [ChatClient.ProjectInfo] {
        var list = client.projects
        if let spaceFilter {
            list = list.filter { $0.spaceID?.uuidString == spaceFilter }
        }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return list }
        return list.filter {
            $0.name.lowercased().contains(needle) || $0.path.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                agentPicker
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                List {
                    ForEach(projects) { project in
                        Button {
                            guard let agent else { return }
                            client.launch(project: project.id, agent: agent)
                        } label: {
                            projectRow(project)
                        }
                        .buttonStyle(.plain)
                        .termiteRow(theme)
                    }
                }
                .listStyle(.insetGrouped)
                .listSectionSpacing(.compact)
            }
            .termiteScreen(theme)
            .searchable(text: $query, prompt: Text("搜索项目"))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("唤起 agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .overlay {
                if client.launching {
                    ProgressView("正在启动…")
                        .padding(20)
                        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .onAppear {
            // 默认选 Claude Code —— 大概率就是你要的那家
            agent = client.agents.first { $0.command == "claude" } ?? client.agents.first
        }
    }

    private var agentPicker: some View {
        HStack(spacing: 6) {
            ForEach(client.agents) { option in
                let selected = agent?.id == option.id
                Button {
                    agent = option
                } label: {
                    Text(option.name)
                        .font(.caption.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 11)
                        .frame(height: 32)
                        .background(
                            selected ? theme.accent : theme.surface,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .foregroundStyle(selected ? theme.accentForeground : theme.primaryText)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func projectRow(_ project: ChatClient.ProjectInfo) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(project.accent.map { Color(UIColor(hex: $0)) } ?? theme.tertiaryText)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                Text((project.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.tertiaryText)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// 气泡界面。工具调用折成一行、思考默认收起 ——
/// 一场会话几百次 tool_use,全展开会把正文淹掉
struct ChatView: View {
    let client: ChatClient
    let session: ChatClient.SessionInfo

    @Environment(\.dismiss) private var dismiss
    @Environment(\.termiteTheme) private var theme
    @State private var draft = ""
    @State private var expandedThinking: Set<String> = []
    @State private var showTerminal = false

    /// 列表在后台每 3 秒刷一次,这里用最新的那份 ——
    /// 否则 canSend / 等待状态会永远停在你点进来的那一刻
    private var live: ChatClient.SessionInfo {
        client.sessions.first { $0.id == session.id } ?? session
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            waitingBanner
            composer
        }
        .termiteScreen(theme)
        .navigationTitle(live.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 权限提示、斜杠命令这些纯 TUI 的东西转录里没有,必须留这个出口
                Button {
                    showTerminal = true
                } label: {
                    Image(systemName: "terminal")
                }
                .help("切到终端视图")
            }
        }
        .onDisappear { client.detach(session.id) }
        .fullScreenCover(isPresented: $showTerminal) {
            TerminalFallbackView(sessionID: session.id, title: live.title)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if client.loading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .padding(.vertical, 40)
                    } else if client.retrying {
                        // 刚唤起:agent 起来后才写第一份转录,这几秒别吓唬人
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("正在启动 agent…")
                                .font(.system(size: 13))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else if client.messages.isEmpty, !client.unavailable {
                        ContentUnavailableView("这个会话还没有对话",
                                               systemImage: "bubble.left",
                                               description: Text("在这里发一句就能开始"))
                            .padding(.top, 40)
                    }
                    if client.unavailable, !client.retrying {
                        Label("读不到这个会话的转录,去终端看", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    ForEach(client.messages) { message in
                        bubble(message).id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: client.messages.count) {
                guard let last = client.messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder private func bubble(_ message: ChatClient.Message) -> some View {
        if message.thinking {
            thinkingBlock(message)
        } else {
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                if !message.text.isEmpty {
                    Text(attributed(message.text))
                        .font(.system(size: 15))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(message.isUser ? theme.accent.opacity(0.22) : theme.surface)
                        )
                        .frame(maxWidth: .infinity,
                               alignment: message.isUser ? .trailing : .leading)
                }
                ForEach(message.tools, id: \.self) { tool in
                    toolRow(tool)
                }
            }
            .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
        }
    }

    private func toolRow(_ tool: ChatClient.Message.ToolCall) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(tool.name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            Text(tool.summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(theme.surface))
    }

    private func thinkingBlock(_ message: ChatClient.Message) -> some View {
        let expanded = expandedThinking.contains(message.id)
        return Button {
            if expanded { expandedThinking.remove(message.id) }
            else { expandedThinking.insert(message.id) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("思考")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.tertiary)
                if expanded {
                    Text(message.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var waitingBanner: some View {
        if let error = client.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
        } else if live.canSend == false {
            // 同目录下常混着普通 shell,绑到它的话发消息等于在 bash 里执行一句话。
            // 只说「不能发」等于把人堵死,给一条就地重开的出路
            HStack(spacing: 8) {
                Label("agent 没在运行,只能看历史", systemImage: "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 4)
                if let option = relaunchOption, let cwd = live.cwd {
                    Button {
                        client.launch(cwd: cwd, agent: option)
                    } label: {
                        if client.launching {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("启动 \(option.name)", systemImage: "play.fill")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(client.launching)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(theme.surface)
        } else if live.attention == "input" {
            Button {
                showTerminal = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bell.badge.fill")
                    Text("正在等你确认 · 去终端")
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }
            .buttonStyle(.plain)
        }
    }

    /// 就地重开时用哪家:优先这段转录本来的那家,其次 Mac 上装了的第一家
    private var relaunchOption: ChatClient.AgentOption? {
        client.agents.first { $0.name == live.agent } ?? client.agents.first
    }

    /// 占位文字点名当前这家 agent —— 三家都接了,写死「跟 Claude 说」会误导
    private var placeholder: String {
        if live.canSend == false { return String(localized: "agent 没在运行") }
        let name = live.agent.isEmpty ? "agent" : live.agent
        return String(localized: "跟 \(name) 说…")
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Capsule().fill(theme.surface))
            Button {
                client.send(text: draft)
                draft = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || live.canSend == false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.background)
        .overlay(alignment: .top) { theme.separator.frame(height: 0.5) }
    }

    /// 简单 markdown:粗体/行内代码/链接交给 AttributedString,
    /// 代码块暂时按原样(等手感确认后再决定要不要上高亮)
    private func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// 对话页跳终端:复用现有终端视图,拿会话摘要包一层
private struct TerminalFallbackView: View {
    let sessionID: UUID
    let title: String

    @Environment(\.dismiss) private var dismiss
    @Environment(ConnectionStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if let summary = summary {
                    TerminalScreenView(client: terminalClient, session: summary)
                } else {
                    ProgressView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("返回对话") { dismiss() }
                }
            }
        }
        .onAppear {
            if let mac = store.selected, let endpoint = store.endpoint(for: mac) {
                terminalClient.configure(endpoint)
            }
        }
    }

    @State private var terminalClient = RemoteClient()

    private var summary: RemoteSessionSummary? {
        terminalClient.sessions.first { $0.id == sessionID }
    }
}
