import AppKit
import SwiftUI

/// 终端区底部状态栏,三段式:左=shell/工作目录/命令状态,中=git 分支+提交身份(几何居中),
/// 右=时钟+行列数。跟随当前选中会话,时钟每秒刷新。
struct StatusBarView: View {
    let session: TerminalSession
    @Environment(SessionManager.self) private var sessionManager

    /// 结构化输出查看器弹层
    @State private var structuredTarget: CommandRecord?
    @State private var dirHovering = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // 两侧各占一半弹性宽度,中段自然落在条的正中,不再挤在左串尾巴上
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    sessionItems(now: context.date)
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity)
                gitItems
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    Text(context.date.formatted(date: .omitted, time: .standard))
                        .foregroundStyle(.tertiary)
                    separatorDot
                    Text("\(session.terminalView.getTerminal().cols)×\(session.terminalView.getTerminal().rows)")
                        .foregroundStyle(.tertiary)
                        .help("终端列数 × 行数")
                }
                .frame(maxWidth: .infinity)
            }
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(
                Capsule()
                    .fill(theme.elevatedBackground)
                    .overlay(Capsule().stroke(theme.borderColor, lineWidth: 1))
                    .shadow(color: .black.opacity(0.22), radius: 7, y: 2)
            )
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .sheet(item: $structuredTarget) { record in
            StructuredOutputView(session: session, record: record) {
                structuredTarget = nil
            }
        }
    }

    /// 左段:shell + 工作目录 + 命令状态 + 本地 URL + 结构化输出 + 录制
    @ViewBuilder private func sessionItems(now: Date) -> some View {
        Circle()
            .fill(session.state == .running ? Color.green : Color.red)
            .frame(width: 6, height: 6)
        Text(session.shellName)
            .foregroundStyle(.secondary)
        if let dir = session.workingDirectory {
            separatorDot
            // 顶部标题胶囊已移除(与此处重复),点按打开 Finder 的入口挪到这里
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
            } label: {
                Text((dir as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(dirHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 320, alignment: .leading)
            }
            .buttonStyle(.plain)
            .animation(.easeOut(duration: 0.12), value: dirHovering)
            .onHover { dirHovering = $0 }
            .help("在 Finder 中打开 \((dir as NSString).abbreviatingWithTildeInPath)")
        }
        if session.runningCommand {
            separatorDot
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(runningText(now: now))
            }
            .foregroundStyle(.secondary)
        } else if let code = session.lastExitCode {
            separatorDot
            HStack(spacing: 3) {
                Image(systemName: code == 0 ? "checkmark" : "xmark")
                if code != 0 { Text("\(code)") }
                if let duration = durationText(session.lastCommandDuration) {
                    Text(duration)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(code == 0 ? Color.green : Color.red)
            .help(code == 0 ? "上条命令成功" : "上条命令退出码 \(code)")
        }
        if let url = session.detectedLocalURL {
            separatorDot
            Button {
                if let opened = URL(string: url) { NSWorkspace.shared.open(opened) }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "globe")
                    Text(URL(string: url)?.port.map { ":\($0)" } ?? url)
                }
                .foregroundStyle(theme.accentColor)
            }
            .buttonStyle(.plain)
            .help("在浏览器打开 \(url)")
        }
        if !session.runningCommand,
           let last = session.commandHistory.last,
           let format = last.structured, last.hasOutput {
            separatorDot
            Button {
                structuredTarget = last
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: format.symbol)
                    Text(format.label)
                }
                .foregroundStyle(theme.accentColor)
            }
            .buttonStyle(.plain)
            .help("上条命令输出像 \(format.label),点击结构化查看")
        }
        if session.isLogging || session.isCasting {
            separatorDot
            HStack(spacing: 3) {
                Image(systemName: "record.circle")
                Text(session.isCasting ? "REC" : "录制中")
            }
            .foregroundStyle(.red)
            .help((session.castURL ?? session.logURL)?.path ?? "")
        }
    }

    /// 中段:git 分支(+脏计数)与提交身份;间距放宽,不与两侧共挤一串
    @ViewBuilder private var gitItems: some View {
        HStack(spacing: 10) {
            if let branch = session.gitBranch {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        sessionManager.toggleGitPanel()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.trianglehead.branch")
                            .font(.system(size: 9))
                        Text(branch)
                        if let dirty = session.gitDirtyCount, dirty > 0 {
                            // 圆点用几何形状而非字符 ●:字符跟字体基线走,竖直中心是歪的
                            HStack(spacing: 2.5) {
                                Circle()
                                    .fill(Color.yellow)
                                    .frame(width: 6, height: 6)
                                Text("\(dirty)")
                                    .foregroundStyle(.yellow)
                            }
                        }
                    }
                    .foregroundStyle(theme.accentColor)
                }
                .buttonStyle(.plain)
                .help("Git 面板(⌘G)· \(session.gitDirtyCount ?? 0) 个未提交文件")
            }
            if session.gitBranch != nil, let dir = session.workingDirectory {
                separatorDot
                GitEmailStatusItem(workingDirectory: dir)
            }
        }
    }

    private var separatorDot: some View {
        Text("·").foregroundStyle(.quaternary)
    }

    /// 运行中命令的实时耗时:运行中 3s / 1m12s
    private func runningText(now: Date) -> String {
        guard let since = session.commandRunningSince else { return String(localized: "运行中") }
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        let text = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m\(seconds % 60)s"
        return String(localized: "运行中 \(text)")
    }

    /// 命令耗时的紧凑格式:0.4s / 2.1s / 1m23s;不足 0.1s 不显示
    private func durationText(_ duration: TimeInterval?) -> String? {
        guard let duration, duration >= 0.1 else { return nil }
        if duration < 60 { return String(format: "%.1fs", duration) }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return "\(minutes)m\(seconds)s"
    }
}

/// git user.email 展示项:双身份(工作/个人)场景一眼看清当前提交身份,点击弹出编辑。
/// 目录切换时重查;编辑弹层关闭后重查,让改动立即反映到条上。
private struct GitEmailStatusItem: View {
    let workingDirectory: String

    @State private var email = ""
    @State private var hasLocalOverride = false
    @State private var editing = false

    var body: some View {
        Button {
            editing.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 9))
                Text(email.isEmpty ? String(localized: "邮箱未设置") : email)
            }
            .foregroundStyle(email.isEmpty ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 200)
        }
        .buttonStyle(.plain)
        .help(hasLocalOverride ? "git 提交邮箱(本仓库覆盖),点击编辑" : "git 提交邮箱(全局),点击编辑")
        .popover(isPresented: $editing, arrowEdge: .top) {
            GitIdentityView(repoRoot: workingDirectory)
        }
        .task(id: workingDirectory) { await load() }
        .onChange(of: editing) { _, showing in
            if !showing { Task { await load() } }
        }
    }

    private func load() async {
        let identity = await GitService.identity(in: workingDirectory)
        email = identity.email
        hasLocalOverride = identity.hasLocal
    }
}
