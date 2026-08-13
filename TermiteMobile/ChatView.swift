import SwiftUI

/// 对话 tab 的会话列表:只列有 agent 转录的会话。
/// 普通 shell 归终端 tab —— 这个 tab 的心智是「我的 AI 会话」
struct ChatSessionListView: View {
    let client: ChatClient

    @Environment(ConnectionStore.self) private var store
    @Environment(\.termiteTheme) private var theme
    /// 工作空间筛选:和终端 tab 同一套语义 —— 未分组的会话在所有空间都可见
    @State private var spaceFilter: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if client.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("没有 AI 会话", systemImage: "bubble.left.and.text.bubble.right")
                    } description: {
                        Text("在 Mac 上用 Claude Code 开一个会话就会出现在这里")
                    }
                } else {
                    List {
                        if !client.spaces.isEmpty {
                            Section {
                                spaceSelector
                                    .listRowInsets(EdgeInsets(top: 6, leading: 12,
                                                              bottom: 6, trailing: 12))
                                    .listRowBackground(Color.clear)
                            }
                        }
                        Section {
                            ForEach(visibleSessions) { session in
                                NavigationLink(value: session) { row(session) }
                                    .termiteRow(theme)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .termiteScreen(theme)
            .navigationTitle("对话")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { client.refresh() }
            .navigationDestination(for: ChatClient.SessionInfo.self) { session in
                ChatView(client: client, session: session)
                    .onAppear { client.attach(session.id) }
            }
        }
        .onAppear {
            if let mac = store.selected, let endpoint = store.endpoint(for: mac) {
                client.connect(endpoint)
            }
            client.refresh()
        }
    }

    /// 未分组会话在所有空间可见(对齐 Mac 侧边栏与终端 tab)
    private var visibleSessions: [ChatClient.SessionInfo] {
        guard let spaceFilter else { return client.sessions }
        return client.sessions.filter { $0.spaceID == spaceFilter || $0.spaceID == nil }
    }

    private var spaceSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: String(localized: "全部"), value: nil)
                ForEach(client.spaces) { space in
                    chip(title: space.name, value: space.id)
                }
            }
        }
    }

    private func chip(title: String, value: UUID?) -> some View {
        let selected = spaceFilter == value
        return Button {
            spaceFilter = value
        } label: {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? theme.accent.opacity(0.22) : theme.surface))
                .foregroundStyle(selected ? theme.accent : theme.secondaryText)
        }
        .buttonStyle(.plain)
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

    var body: some View {
        VStack(spacing: 0) {
            messageList
            waitingBanner
            composer
        }
        .termiteScreen(theme)
        .navigationTitle(session.title)
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
        .onDisappear { client.detach() }
        .fullScreenCover(isPresented: $showTerminal) {
            TerminalFallbackView(sessionID: session.id, title: session.title)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if client.loading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .padding(.vertical, 40)
                    } else if client.messages.isEmpty, !client.unavailable {
                        ContentUnavailableView("这个会话还没有对话",
                                               systemImage: "bubble.left",
                                               description: Text("在这里发一句就能开始"))
                            .padding(.top, 40)
                    }
                    if client.unavailable {
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
        } else if session.canSend == false {
            // 同目录下常混着普通 shell,绑到它的话发消息等于在 bash 里执行一句话
            Label("这个目录的 agent 没在运行,只能查看历史", systemImage: "eye")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(theme.surface)
        } else if session.attention == "input" {
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

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(session.canSend == false ? "agent 没在运行" : "跟 Claude 说…",
                      text: $draft, axis: .vertical)
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
                      || session.canSend == false)
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
