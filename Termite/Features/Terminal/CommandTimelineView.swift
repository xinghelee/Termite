import SwiftUI

/// 右侧命令时间线:OSC 133 记录的每条命令(文本/退出码/耗时/时间),
/// 点击滚动定位到该命令,悬停可复制命令文本或完整输出。
struct CommandTimelineView: View {
    let session: TerminalSession
    let onClose: () -> Void

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("命令时间线", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().overlay(theme.borderColor)

            if session.commandHistory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("还没有命令记录")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("依赖 shell 集成(OSC 133),zsh 已自动注入")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(session.commandHistory.reversed()) { record in
                            CommandRecordRow(record: record, session: session)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: 288)
        .background(theme.panelBackground)
    }
}

private struct CommandRecordRow: View {
    let record: CommandRecord
    let session: TerminalSession

    @State private var hovering = false
    @State private var copiedFlash = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(record.commandText.isEmpty ? "(空命令)" : record.commandText)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    Image(systemName: record.succeeded ? "checkmark" : "xmark")
                        .font(.system(size: 8, weight: .bold))
                    if let code = record.exitCode, code != 0 {
                        Text("\(code)")
                    }
                }
                .foregroundStyle(record.succeeded ? Color.green : Color.red)
                if let duration = record.duration, duration >= 0.1 {
                    Text(Self.compact(duration))
                        .foregroundStyle(.secondary)
                }
                Text(record.finishedAt.formatted(date: .omitted, time: .shortened))
                    .foregroundStyle(.tertiary)
                Spacer()
                if copiedFlash {
                    Text("已复制")
                        .foregroundStyle(theme.accentColor)
                } else if hovering {
                    Button {
                        flashIfCopied(session.copyOutput(of: record))
                    } label: {
                        Image(systemName: "text.viewfinder")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(!record.hasOutput)
                    .help("复制这条命令的输出")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.commandText, forType: .string)
                        flashIfCopied(true)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("复制命令行文本")
                }
            }
            .font(.system(size: 10).monospacedDigit())
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.primary.opacity(0.06) : theme.elevatedBackground.opacity(0.5))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .onTapGesture { session.scrollTo(record: record) }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("点击定位到这条命令")
    }

    private func flashIfCopied(_ ok: Bool) {
        guard ok else { return }
        copiedFlash = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copiedFlash = false
        }
    }

    private static func compact(_ duration: TimeInterval) -> String {
        if duration < 60 { return String(format: "%.1fs", duration) }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return "\(minutes)m\(seconds)s"
    }
}
