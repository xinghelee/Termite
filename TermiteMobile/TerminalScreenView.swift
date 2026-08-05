import SwiftUI

/// 终端画面:iPhone 栈式推入 / iPad 双栏详情通用。
/// 普通 shell 默认按本机网格显示；TUI 固定语义网格后在每台设备上独立缩放。
/// chrome 同色:导航栏/按键条与终端主题同底,一块完整的「面」(与 Mac 端设计语言一致)。
struct TerminalScreenView: View {
    let client: RemoteClient
    let session: RemoteSessionSummary

    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @AppStorage(MobileSettingsKeys.fontSize) private var fontSize = MobileSettingsKeys.defaultFontSize
    @AppStorage(MobileSettingsKeys.keepAwake) private var keepAwake = true
    @AppStorage(MobileSettingsKeys.bellHaptics) private var bellHaptics = true

    @State private var bridge = TerminalBridge()
    @State private var ctrlArmed = false
    @State private var endedMessage: String?
    @State private var pinchBase: Double?
    /// true = 适配设备(默认);false = 镜像 Mac(整体缩放)
    @State private var fitMode = true
    /// TUI 默认优先可读性；完整画布仅是当前设备的总览开关。
    @State private var tuiShowsFullCanvas = false
    @State private var keyboardVisible = false
    /// 滚回中(非底部)显示「回到底部」浮钮
    @State private var atBottom = true

    // MARK: - 主题派生色(chrome 与终端同一块面)

    private var themeIsDark: Bool { client.theme?.isDark ?? true }

    private var themeBackground: Color {
        client.theme.map { Color(UIColor(hex: $0.background)) } ?? Color(red: 0.078, green: 0.086, blue: 0.102)
    }

    private var themeAccent: Color {
        client.theme.map { Color(UIColor(hex: $0.accent)) } ?? Color(red: 0.91, green: 0.64, blue: 0.24)
    }

    /// 按键底色:主题底上抬一层(深色抬白、浅色压黑)
    private var keyFill: Color {
        themeIsDark ? Color.white.opacity(0.09) : Color.black.opacity(0.06)
    }

    private var keyText: Color {
        client.theme.map { Color(UIColor(hex: $0.foreground)) } ?? .primary
    }

    /// TUI 必须完整呈现固定画布；普通 shell 尊重用户的本机适配选择。
    private var shouldMirror: Bool {
        !fitMode || client.tuiMode
    }

    var body: some View {
        VStack(spacing: 0) {
            terminalArea
            keyBar
                .frame(maxWidth: 620)
        }
        .frame(maxWidth: .infinity)
        .background(themeBackground.ignoresSafeArea())
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        // chrome 同色:导航栏融进终端主题,不再是一条系统灰
        .toolbarBackground(themeBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(themeIsDark ? .dark : .light, for: .navigationBar)
        .tint(themeAccent)
        .toolbar { toolbarContent }
        .onAppear { activate() }
        .onDisappear { deactivate() }
        .onChange(of: keepAwake) { UIApplication.shared.isIdleTimerDisabled = keepAwake }
        .onChange(of: bellHaptics) { bridge.hapticsEnabled = bellHaptics }
        .onChange(of: fontSize) { applyFont() }
        .onChange(of: fitMode) { applyMode() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .alert("会话已结束", isPresented: Binding(
            get: { endedMessage != nil },
            set: { if !$0 { endedMessage = nil } }
        )) {
            Button("好") {
                endedMessage = nil
                dismiss()
            }
        } message: {
            Text(endedMessage ?? "")
        }
    }

    // MARK: - 终端区(重连横幅 + 回到底部浮钮)

    private var terminalArea: some View {
        TerminalCanvas(
            bridge: bridge,
            mirror: shouldMirror,
            mirrorSize: bridge.mirrorContentSize(cols: client.gridCols, rows: client.gridRows,
                                                 fontSize: CGFloat(fontSize)),
            pinnedGrid: shouldMirror ? (client.gridCols, client.gridRows) : nil,
            fitsEntireCanvas: !client.tuiMode || tuiShowsFullCanvas
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            // 非阻塞横幅:重连中内容照常可见,别拿全屏遮罩挡人
            if client.phase == .connecting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("重连中…")
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.ultraThinMaterial))
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !atBottom {
                Button {
                    bridge.scrollToBottom()
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(10)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: client.phase)
        .animation(.easeOut(duration: 0.18), value: atBottom)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if client.tuiMode {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    tapHaptic()
                    tuiShowsFullCanvas.toggle()
                } label: {
                    Image(systemName: tuiShowsFullCanvas
                          ? "textformat.size"
                          : "arrow.up.left.and.arrow.down.right")
                }
                .help(tuiShowsFullCanvas ? "保持文字可读" : "显示完整会话画布")
                .accessibilityIdentifier("terminal.tui-viewport-mode")
                .accessibilityLabel(tuiShowsFullCanvas ? "清晰视图" : "完整画布")
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    tapHaptic()
                    fitMode.toggle()
                } label: {
                    Image(systemName: fitMode ? "macwindow" : "iphone")
                }
                .help(fitMode ? "显示完整会话画布" : "适配本机宽度")
                .accessibilityIdentifier("terminal.viewport-mode")
                .accessibilityLabel(fitMode ? "显示完整会话画布" : "适配本机")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section(gridLabel) {
                    Button("字号加大", systemImage: "textformat.size.larger") {
                        fontSize = (fontSize + 1).clamped(to: MobileSettingsKeys.fontSizeRange)
                    }
                    Button("字号减小", systemImage: "textformat.size.smaller") {
                        fontSize = (fontSize - 1).clamped(to: MobileSettingsKeys.fontSizeRange)
                    }
                    Button("恢复默认字号", systemImage: "textformat.size") {
                        fontSize = MobileSettingsKeys.defaultFontSize
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
        }
    }

    private var gridLabel: String {
        if client.tuiMode {
            let mode = tuiShowsFullCanvas ? String(localized: "完整画布") : String(localized: "清晰视图")
            return "TUI \(client.gridCols)×\(client.gridRows) · \(mode)"
        }
        if !shouldMirror {
            let grid = bridge.currentGrid()
            return "\(grid.cols)×\(grid.rows) · \(Int(fontSize))pt"
        }
        return String(localized: "镜像 \(client.gridCols)×\(client.gridRows)")
    }

    // MARK: - 模式与尺寸

    private func applyFont() {
        bridge.setFont(size: CGFloat(fontSize))
        syncPresentation()
    }

    private func applyMode() {
        syncPresentation()
    }

    private func syncPresentation() {
        bridge.reportsGridChanges = !shouldMirror
        if !shouldMirror {
            bridge.setFont(size: CGFloat(fontSize))
        } else {
            // 手动完整画布或 TUI：只改变本机呈现，不主动触碰共享 PTY。
            bridge.pinGrid(cols: client.gridCols, rows: client.gridRows)
        }
    }

    // MARK: - 生命周期

    private func activate() {
        bridge.client = client
        bridge.hapticsEnabled = bellHaptics
        bridge.setFont(size: CGFloat(fontSize))
        bridge.onPinchScale = { scale, ended in
            if pinchBase == nil { pinchBase = fontSize }
            fontSize = ((pinchBase ?? fontSize) * scale).clamped(to: MobileSettingsKeys.fontSizeRange)
            if ended { pinchBase = nil }
        }
        bridge.onAtBottomChange = { atBottom = $0 }
        client.onAttached = {
            bridge.reset()
            if let theme = client.theme { bridge.applyTheme(theme) }
            tuiShowsFullCanvas = false
            syncPresentation()
        }
        client.onOutput = { bridge.feed($0) }
        client.onSessionEnded = { endedMessage = $0 }
        client.onViewportChange = {
            syncPresentation()
        }
        if let theme = client.theme { bridge.applyTheme(theme) }
        client.attach(session.id)
        if let mac = store.selected { store.rememberSession(session.id, of: mac) }
        UIApplication.shared.isIdleTimerDisabled = keepAwake
    }

    /// iPad 双栏切换会话时,新视图的 activate 可能先于旧视图的 deactivate:
    /// 只有当自己仍是附着方时才解附/清回调,避免拆掉新会话的桥
    private func deactivate() {
        UIApplication.shared.isIdleTimerDisabled = false
        guard client.attachedID == session.id else { return }
        client.detach()
        client.onAttached = nil
        client.onOutput = nil
        client.onSessionEnded = nil
        client.onViewportChange = nil
    }

    // MARK: - 按键条(与终端同底,按键为主题上的浮层)

    private var keyBar: some View {
        HStack(spacing: 4) {
            keyButton("esc", send: "\u{1b}")
            keyButton("tab", send: "\t")
            ctrlButton
            keyButton("^C", send: "\u{03}")
            repeatKeyButton("↑", send: "\u{1b}[A")
            repeatKeyButton("↓", send: "\u{1b}[B")
            repeatKeyButton("←", send: "\u{1b}[D")
            repeatKeyButton("→", send: "\u{1b}[C")
            keyButton("⏎", send: "\r")
            moreKeysMenu
            keyboardToggle
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var ctrlButton: some View {
        Button {
            tapHaptic()
            ctrlArmed.toggle()
        } label: {
            Text("ctrl")
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(ctrlArmed ? themeAccent : keyFill)
                .foregroundStyle(ctrlArmed ? Color.black : keyText)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var moreKeysMenu: some View {
        Menu {
            Button("^D 结束输入") { sendKey("\u{04}") }
            Button("^Z 挂起") { sendKey("\u{1a}") }
            Button("^L 清屏") { sendKey("\u{0c}") }
            Button("^R 搜索历史") { sendKey("\u{12}") }
            Divider()
            Button("Home") { sendKey("\u{1b}[H") }
            Button("End") { sendKey("\u{1b}[F") }
            Button("Page Up") { sendKey("\u{1b}[5~") }
            Button("Page Down") { sendKey("\u{1b}[6~") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(keyFill)
                .foregroundStyle(keyText)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// 收起/呼出键盘:半屏键盘挡终端是手机第一痛点,给个一键开关
    private var keyboardToggle: some View {
        Button {
            tapHaptic()
            if keyboardVisible {
                _ = bridge.terminalView.resignFirstResponder()
            } else {
                _ = bridge.terminalView.becomeFirstResponder()
            }
        } label: {
            Image(systemName: keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                .font(.system(size: 13))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(keyFill)
                .foregroundStyle(keyText)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func keyButton(_ label: String, send: String) -> some View {
        Button {
            sendKey(send)
        } label: {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(keyFill)
                .foregroundStyle(keyText)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// 方向键长按连发(0.4s 起步,80ms/次)——TUI 菜单里单点太折磨
    private func repeatKeyButton(_ label: String, send: String) -> some View {
        RepeatKeyButton(label: label, fill: keyFill, textColor: keyText) { sendKey(send) }
    }

    private func sendKey(_ text: String) {
        tapHaptic()
        // ctrl 粘滞:armed 时下一个字母键转控制码(a→^A)
        if ctrlArmed, text.count == 1, let scalar = text.uppercased().unicodeScalars.first,
           scalar.value >= 64, scalar.value < 96 {
            ctrlArmed = false
            client.sendInput(Data([UInt8(scalar.value & 0x1f)]))
            return
        }
        ctrlArmed = false
        client.sendInput(text)
    }

    private func tapHaptic() {
        guard bellHaptics else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
    }
}

/// 按下即发一次,按住 0.4s 后以 80ms 间隔连发
private struct RepeatKeyButton: View {
    let label: String
    let fill: Color
    let textColor: Color
    let fire: () -> Void

    @State private var pressed = false
    @State private var repeater: Task<Void, Never>?

    var body: some View {
        Text(label)
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(pressed ? Color.gray.opacity(0.4) : fill)
            .foregroundStyle(textColor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        fire()
                        repeater = Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            while !Task.isCancelled {
                                fire()
                                try? await Task.sleep(for: .milliseconds(80))
                            }
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        repeater?.cancel()
                        repeater = nil
                    }
            )
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
