import SwiftUI

/// 终端区底部状态栏:shell + 工作目录 + git 分支 + 上条命令退出码/耗时 | 时钟 + 行列数。
/// 跟随当前选中会话,时钟每秒刷新。
struct StatusBarView: View {
    let session: TerminalSession

    /// 结构化输出查看器弹层
    @State private var structuredTarget: CommandRecord?

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                Circle()
                    .fill(session.state == .running ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(session.shellName)
                    .foregroundStyle(.secondary)
                if let dir = session.workingDirectory {
                    separatorDot
                    Text((dir as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 320, alignment: .leading)
                }
                if let branch = session.gitBranch {
                    separatorDot
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.trianglehead.branch")
                            .font(.system(size: 9))
                        Text(branch)
                    }
                    .foregroundStyle(theme.accentColor)
                    .help("git 分支")
                }
                if session.runningCommand {
                    separatorDot
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(runningText(now: context.date))
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
                if session.isLogging {
                    separatorDot
                    HStack(spacing: 3) {
                        Image(systemName: "record.circle")
                        Text("录制中")
                    }
                    .foregroundStyle(.red)
                    .help(session.logURL?.path ?? "")
                }

                Spacer()

                Text(context.date.formatted(date: .omitted, time: .standard))
                    .foregroundStyle(.tertiary)
                separatorDot
                Text("\(session.terminalView.getTerminal().cols)×\(session.terminalView.getTerminal().rows)")
                    .foregroundStyle(.tertiary)
                    .help("终端列数 × 行数")
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
