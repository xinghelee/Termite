import SwiftUI

/// 应答 tab 的列表。
///
/// 定位不是「我的 AI 会话」,是「谁在等我」—— 手机上最锐利的场景只有这一个。
/// 所以「等你回复」是第一屏的主角(带问题原文,不点进去也知道该不该现在管),
/// 其余会话降级成「最近」,只是上下文
struct ChatSessionListView: View {
    let client: ChatClient
    let notifier: ReplyNotifier

    @Environment(\.termiteTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 工作空间筛选:和终端 tab 同一套语义 —— 未分组的会话在所有空间都可见。
    /// 存 uuidString 而不是 UUID,是为了和终端共用 SpaceFilterBar
    @State private var spaceFilter: String?
    @State private var path: [ChatClient.SessionInfo] = []
    @State private var showLaunch = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .termiteScreen(theme)
                .navigationTitle("会话")
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
                    ReplyView(client: client, session: session)
                        .onAppear { client.attach(session.id) }
                        // 二级页把底部让给选项和输入框
                        .toolbar(.hidden, for: .tabBar)
                }
        }
        .sheet(isPresented: $showLaunch) {
            LaunchAgentSheet(client: client, spaceFilter: spaceFilter)
        }
        .onChange(of: client.launched) { _, launched in
            // Mac 那边新 pane 开好了:关掉选择面板,直接推进应答页
            guard let launched else { return }
            showLaunch = false
            path = [launched]
            client.consumeLaunched()
        }
        .onAppear {
            notifier.requestAuthorizationIfNeeded()
            consumePendingNotification()
        }
        .onChange(of: notifier.pendingSessionID) { consumePendingNotification() }
        .onChange(of: client.sessions) { consumePendingNotification() }
    }

    @ViewBuilder private var content: some View {
        if client.sessions.isEmpty {
            ContentUnavailableView {
                Label("没有 AI 会话", systemImage: "bubble.left.and.text.bubble.right")
            } description: {
                Text(client.agents.isEmpty
                     ? "在 Mac 上开一个 agent 会话就会出现在这里"
                     : "点右上角的 + 直接在 Mac 上唤起一个")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !client.spaces.isEmpty {
                        SpaceFilterBar(
                            options: client.spaces.map { .init(id: $0.id.uuidString, title: $0.name) },
                            selection: $spaceFilter,
                            theme: theme
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }
                    waitingSection
                    recentSection
                }
                .padding(.bottom, 24)
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: waitingIDs)
        }
    }

    // MARK: - 等你回复

    @ViewBuilder private var waitingSection: some View {
        let sessions = visibleSessions.filter(\.isWaiting)
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: String(localized: "等你回复"), count: sessions.count,
                          symbol: "bell.badge.fill", color: .orange,
                          highlighted: !sessions.isEmpty)
            if sessions.isEmpty {
                // 空着才是常态。应答器安静的时候就该看起来是安静的,而不是一片空白
                Label("没有 agent 在等你", systemImage: "checkmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                ForEach(sessions) { session in
                    NavigationLink(value: session) { waitingCard(session) }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private func waitingCard(_ session: ChatClient.SessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(session.projectColor.map { Color(UIColor(hex: $0)) } ?? .orange)
                    .frame(width: 7, height: 7)
                Text(session.project ?? session.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(waitDescription(session))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            }
            // 问题原文就是这张卡片存在的理由
            Text(session.question ?? String(localized: "正在等你确认"))
                .font(.system(size: 15))
                .foregroundStyle(theme.primaryText)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(session.agent)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
                Spacer()
                Text("去回复")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }

    // MARK: - 最近

    @ViewBuilder private var recentSection: some View {
        let sessions = visibleSessions.filter { !$0.isWaiting }
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(title: String(localized: "最近"), count: sessions.count,
                              symbol: nil, color: theme.tertiaryText, highlighted: false)
                ForEach(sessions) { session in
                    NavigationLink(value: session) { recentRow(session) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
        }
    }

    private func recentRow(_ session: ChatClient.SessionInfo) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.projectColor.map { Color(UIColor(hex: $0)) } ?? theme.tertiaryText)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(shortPath(session.cwd) + " · " + session.agent)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if session.canSend == false {
                // 只能看历史:pane 底下没挂 agent
                Image(systemName: "eye")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
            }
            Text(relative(session.lastActivity))
                .font(.system(size: 11))
                .foregroundStyle(theme.tertiaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }

    private func sectionHeader(title: String, count: Int, symbol: String?,
                               color: Color, highlighted: Bool) -> some View {
        HStack(spacing: 7) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .symbolEffect(.bounce, value: waitingIDs)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(highlighted ? color : theme.secondaryText)
            Spacer(minLength: 8)
            if count > 0 {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.tertiaryText)
            }
        }
    }

    // MARK: - 数据

    /// 未分组会话在所有空间可见(对齐 Mac 侧边栏与终端 tab)
    private var visibleSessions: [ChatClient.SessionInfo] {
        guard let spaceFilter else { return client.sessions }
        return client.sessions.filter {
            $0.spaceID?.uuidString == spaceFilter || $0.spaceID == nil
        }
    }

    private var waitingIDs: Set<UUID> {
        Set(client.waiting.map(\.id))
    }

    private func waitDescription(_ session: ChatClient.SessionInfo) -> String {
        guard let seconds = session.attentionSeconds, seconds >= 60 else {
            return String(localized: "刚刚")
        }
        if seconds < 3600 { return String(localized: "已等 \(seconds / 60) 分钟") }
        return String(localized: "已等 \(seconds / 3600) 小时")
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

    /// 点通知进来:等这个会话出现在列表里再推页面。
    /// 通知可能比 chatList 先到,所以 sessions 更新时也要再试一次
    private func consumePendingNotification() {
        guard let id = notifier.pendingSessionID,
              let session = client.sessions.first(where: { $0.id == id }) else { return }
        notifier.pendingSessionID = nil
        path = [session]
    }
}

/// 应答界面。
///
/// 主角是「它在等什么」那块面板:问题原文 + 一按就回的选项。
/// 转录退居上方当上下文 —— 手机上你需要的是回答,不是通读。
struct ReplyView: View {
    let client: ChatClient
    let session: ChatClient.SessionInfo

    @Environment(\.termiteTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var expandedThinking: Set<String> = []
    @State private var showTerminal = false
    /// 刚按下的那个选项。画面变了就清掉 —— 那说明这一答已经落地
    @State private var answered: (label: String, screen: String)?

    /// 列表在后台每 3 秒刷一次,这里用最新的那份 ——
    /// 否则 canSend / 等待状态会永远停在你点进来的那一刻
    private var live: ChatClient.SessionInfo {
        client.sessions.first { $0.id == session.id } ?? session
    }

    /// 能不能发东西过去:优先信画面那份(每 2 秒一刷,比列表新)
    private var canSend: Bool {
        client.prompt?.canSend ?? (live.canSend != false)
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            errorBanner
            promptArea
            composer
        }
        .termiteScreen(theme)
        .navigationTitle(live.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 应答面板认不出的东西(斜杠命令、多选、自由格式)总得有个出口
                Button {
                    showTerminal = true
                } label: {
                    Image(systemName: "terminal")
                }
                .accessibilityLabel("切到终端视图")
            }
        }
        .onDisappear { client.detach(session.id) }
        .fullScreenCover(isPresented: $showTerminal) {
            TerminalFallbackView(sessionID: session.id, title: live.title)
        }
        .onChange(of: client.prompt?.screen) { _, screen in
            // 画面变了 = 这一答已经落地。清掉「已回复」,让新问题正常显示出来
            if let answered, screen != answered.screen { self.answered = nil }
        }
        .task(id: session.id) {
            // 问「它在等什么」比 chatList 勤:按下选项后的反馈要跟得上手
            while !Task.isCancelled {
                client.requestPrompt()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - 转录(上下文)

    private var transcript: some View {
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
                            .foregroundStyle(theme.secondaryText)
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
                .foregroundStyle(theme.tertiaryText)
            Text(tool.name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
            Text(tool.summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.tertiaryText)
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
                .foregroundStyle(theme.tertiaryText)
                if expanded {
                    Text(message.text)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondaryText)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 应答面板(主角)

    @ViewBuilder private var errorBanner: some View {
        if let error = client.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
        }
    }

    @ViewBuilder private var promptArea: some View {
        if !canSend {
            // 同目录下常混着普通 shell,绑到它的话发消息等于在 bash 里执行一句话。
            // 只说「不能发」等于把人堵死,给一条就地重开的出路
            relaunchBanner
        } else if let answered {
            answeredBanner(answered.label)
        } else if let prompt = client.prompt, prompt.isWaiting || !prompt.options.isEmpty {
            // 注意力判定没触发、但画面上明明摆着一个选择框时也照样给按 ——
            // 那套 bell + 静默的启发式本来就不保证每次都响,不能让它卡住唯一的回复通道
            PromptPanel(prompt: prompt, theme: theme, onKey: press)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var relaunchBanner: some View {
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
    }

    /// 答完了就该说清楚「答的是哪个、接下来在等什么」,
    /// 而不是把面板一收让人怀疑刚才那下有没有发出去
    private func answeredBanner(_ label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.green)
            Text("已回复「\(label)」")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 6)
            ProgressView().controlSize(.small)
            Text("等 agent 继续")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .overlay(alignment: .top) { theme.separator.frame(height: 0.5) }
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
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.background)
        .overlay(alignment: .top) { theme.separator.frame(height: 0.5) }
    }

    // MARK: - 动作

    private func press(_ key: String, label: String) {
        guard let screen = client.prompt?.screen else { return }
        client.sendKey(key)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            answered = (label, screen)
        }
        Task {
            try? await Task.sleep(for: .seconds(10))
            // 画面十秒都没变 = 这一按没起作用。把选项还回去,
            // 别让人卡在一个「已回复」上面对着没反应的 agent 干等
            guard answered?.screen == screen else { return }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { answered = nil }
        }
    }

    /// 就地重开时用哪家:优先这段转录本来的那家,其次 Mac 上装了的第一家
    private var relaunchOption: ChatClient.AgentOption? {
        client.agents.first { $0.name == live.agent } ?? client.agents.first
    }

    /// 占位文字点名当前这家 agent —— 三家都接了,写死「跟 Claude 说」会误导
    private var placeholder: String {
        if !canSend { return String(localized: "agent 没在运行") }
        let name = live.agent.isEmpty ? "agent" : live.agent
        return String(localized: "跟 \(name) 说…")
    }

    /// 简单 markdown:粗体/行内代码/链接交给 AttributedString,
    /// 代码块暂时按原样(等手感确认后再决定要不要上高亮)
    private func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// 「它在等什么」+ 一按就回。
///
/// 画面原文和选项按钮都留着:按钮是给手指的,原文是给眼睛的 ——
/// 权限提示里真正要命的信息(到底要执行哪条命令)只在原文里
private struct PromptPanel: View {
    let prompt: ChatClient.Prompt
    let theme: TermiteTheme
    let onKey: (String, String) -> Void

    /// 画面框最高这么多,再多就自己滚。手机上得给选项按钮留住位置
    private static let screenHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let question = prompt.question {
                Text(question)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !prompt.screen.isEmpty {
                ScrollView {
                    Text(prompt.screen)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Self.screenHeight)
                .padding(9)
                .background(theme.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            ForEach(prompt.options) { option in
                optionButton(option)
            }
            keyRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.surface)
        .overlay(alignment: .top) { theme.separator.frame(height: 0.5) }
    }

    private var header: some View {
        // 注意力判定确实响了才用橙色说「等你回复」;
        // 只是画面上有个选择框的话如实说,不假装它在催你
        let waiting = prompt.isWaiting
        return HStack(spacing: 6) {
            Image(systemName: waiting ? "bell.badge.fill" : "list.bullet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(waiting ? .orange : theme.secondaryText)
            Text(waiting ? "等你回复" : "屏幕上的选项")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(waiting ? .orange : theme.secondaryText)
            Spacer()
            if let seconds = prompt.attentionSeconds, seconds >= 60 {
                Text(seconds < 3600
                     ? String(localized: "已等 \(seconds / 60) 分钟")
                     : String(localized: "已等 \(seconds / 3600) 小时"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private func optionButton(_ option: ChatClient.Prompt.Option) -> some View {
        Button {
            onKey(option.id, option.label)
        } label: {
            HStack(spacing: 10) {
                Text(option.id)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(option.selected ? theme.accentForeground : theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(option.selected ? theme.accent : theme.background)
                    )
                Text(option.label)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if option.selected {
                    // agent 光标指着的那个:标出来,但不替人做决定
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.accent.opacity(0.55), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 认不出选项时的兜底,也是「选项不止这几个」时的方向键。
    /// 有它,应答面板才不会在稍微陌生一点的提示前彻底失效
    private var keyRow: some View {
        HStack(spacing: 8) {
            key("return", label: String(localized: "回车"), symbol: "return")
            key("esc", label: String(localized: "取消"), symbol: "escape")
            key("up", label: String(localized: "上"), symbol: "chevron.up")
            key("down", label: String(localized: "下"), symbol: "chevron.down")
            Spacer(minLength: 0)
        }
    }

    private func key(_ id: String, label: String, symbol: String) -> some View {
        Button {
            onKey(id == "return" ? "enter" : id, label)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 40, height: 30)
                .background(theme.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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

/// 应答页跳终端:复用现有终端视图,拿会话摘要包一层
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
                    Button("返回") { dismiss() }
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
