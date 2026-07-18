import SwiftTerm
import SwiftUI

/// asciinema(.cast)回放窗口:终端录像机 —— 播放/暂停/倍速/进度拖拽
struct CastReplayView: View {
    let fileURL: URL

    @State private var player = CastPlayer()

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.borderColor)
            TerminalHostView(terminalView: player.terminalView)
                .padding(.leading, 8)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.chromeBackground)
            Divider().overlay(theme.borderColor)
            controls
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .background(theme.panelBackground)
        .task { player.load(url: fileURL) }
        .onDisappear { player.pause() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("会话回放", systemImage: "play.rectangle")
                .font(.system(size: 12, weight: .semibold))
            Text(fileURL.lastPathComponent)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let error = player.loadError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            Spacer()
            Text("\(player.columns)×\(player.rows)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.accentColor)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(player.duration == 0)

            Text(Self.clock(player.position))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { player.position },
                    set: { player.scrub(to: $0) }
                ),
                in: 0...max(player.duration, 0.01)
            )
            .controlSize(.small)
            .disabled(player.duration == 0)

            Text(Self.clock(player.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)

            Picker("", selection: $player.speed) {
                Text("0.5×").tag(0.5)
                Text("1×").tag(1.0)
                Text("2×").tag(2.0)
                Text("4×").tag(4.0)
                Text("8×").tag(8.0)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 76)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 回放引擎:解析 .cast → 定时喂给无进程的终端视图;seek = 重置后快进重演
@MainActor
@Observable
final class CastPlayer {
    let terminalView: TermiteTerminalView

    private(set) var duration: Double = 0
    private(set) var position: Double = 0
    private(set) var playing = false
    private(set) var columns = 80
    private(set) var rows = 24
    private(set) var loadError: String?
    var speed = 1.0 {
        didSet { if playing { play() } } // 重排播放任务
    }

    @ObservationIgnored private var events: [CastFile.Event] = []
    @ObservationIgnored private var nextIndex = 0
    @ObservationIgnored private var playTask: Task<Void, Never>?

    init() {
        let view = TermiteTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        view.inputEnabled = false
        view.font = FontPrefs.font()
        ThemeStore.shared.apply(to: view)
        terminalView = view
    }

    func load(url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let parsed = CastFile.parse(text) else {
            loadError = String(localized: "无法解析该 .cast 文件")
            return
        }
        columns = parsed.header.width
        rows = parsed.header.height
        events = parsed.events
        duration = parsed.events.last?.time ?? 0
        terminalView.getTerminal().resize(cols: columns, rows: rows)
        seek(to: 0)
        play()
    }

    func togglePlay() {
        playing ? pause() : play()
    }

    func play() {
        playTask?.cancel()
        guard nextIndex < events.count else {
            // 播完从头再来
            seek(to: 0)
            guard !events.isEmpty else { return }
            return play()
        }
        playing = true
        playTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.nextIndex < self.events.count {
                let event = self.events[self.nextIndex]
                let wait = (event.time - self.position) / max(self.speed, 0.1)
                if wait > 0.001 {
                    try? await Task.sleep(for: .seconds(min(wait, 10)))
                    if Task.isCancelled { return }
                }
                self.terminalView.feed(text: event.data)
                self.position = event.time
                self.nextIndex += 1
            }
            self?.playing = false
        }
    }

    func pause() {
        playTask?.cancel()
        playTask = nil
        playing = false
    }

    /// 拖进度条:暂停并跳到目标时间(重置终端,把 ≤t 的事件瞬时重演)
    func scrub(to time: Double) {
        pause()
        seek(to: time)
    }

    private func seek(to time: Double) {
        terminalView.feed(text: "\u{1b}c") // RIS 全量重置
        nextIndex = 0
        var chunk = ""
        while nextIndex < events.count, events[nextIndex].time <= time {
            chunk += events[nextIndex].data
            nextIndex += 1
        }
        if !chunk.isEmpty {
            terminalView.feed(text: chunk)
        }
        position = min(time, duration)
    }
}
