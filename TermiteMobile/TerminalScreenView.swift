import SwiftUI

/// 终端画面:iPhone 栈式推入 / iPad 双栏详情通用。
/// 默认「适配设备」:PTY 跟随本机网格,SwiftTerm 原生滚回滚动,无任何外层滚动视图;
/// 「镜像 Mac」为切换项:按 Mac 网格整体缩放看全貌(Mac 端 resize 会自动切回镜像跟随)。
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
    @State private var resizeDebounce: Task<Void, Never>?
    /// 上次已请求的网格:布局多次落定会重复触发,同尺寸不再打扰 PTY(避免连发 SIGWINCH)
    @State private var lastRequestedGrid: (cols: Int, rows: Int)?

    private var themeBackground: Color {
        client.theme.map { Color(UIColor(hex: $0.background)) } ?? Color(red: 0.078, green: 0.086, blue: 0.102)
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalCanvas(
                bridge: bridge,
                mirror: !fitMode,
                mirrorSize: bridge.mirrorContentSize(cols: client.gridCols, rows: client.gridRows,
                                                     fontSize: CGFloat(fontSize))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(themeBackground)
            keyBar
                .frame(maxWidth: 620)
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onAppear { activate() }
        .onDisappear { deactivate() }
        .onChange(of: keepAwake) { UIApplication.shared.isIdleTimerDisabled = keepAwake }
        .onChange(of: bellHaptics) { bridge.hapticsEnabled = bellHaptics }
        .onChange(of: fontSize) { applyFont() }
        .onChange(of: fitMode) { applyMode() }
        .alert("会话已结束", isPresented: .constant(endedMessage != nil)) {
            Button("好") {
                endedMessage = nil
                dismiss()
            }
        } message: {
            Text(endedMessage ?? "")
        }
        .overlay {
            if client.phase == .connecting {
                ZStack {
                    Color.black.opacity(0.55)
                    ProgressView("重连中…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
                .ignoresSafeArea()
            }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                fitMode.toggle()
            } label: {
                Image(systemName: fitMode ? "macwindow" : "iphone")
            }
            .help(fitMode ? "镜像 Mac 尺寸(整体缩放看全貌)" : "适配本机宽度")
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
        if fitMode {
            let grid = bridge.currentGrid()
            return "\(grid.cols)×\(grid.rows) · \(Int(fontSize))pt"
        }
        return String(localized: "镜像 \(client.gridCols)×\(client.gridRows)")
    }

    // MARK: - 模式与尺寸

    private func applyFont() {
        bridge.setFont(size: CGFloat(fontSize))
        // 适配模式:字号变 → 网格变 → sizeChanged 会走 syncPty;镜像模式只影响缩放比
    }

    private func applyMode() {
        bridge.fitMode = fitMode
        if fitMode {
            bridge.setFont(size: CGFloat(fontSize))
            schedulePtySync()
        } else {
            // 镜像:PTY 还给 Mac 网格,视图钉死同网格再整体缩放
            bridge.pinGrid(cols: client.gridCols, rows: client.gridRows)
            lastRequestedGrid = (client.gridCols, client.gridRows)
            client.requestResize(cols: client.gridCols, rows: client.gridRows)
        }
    }

    /// 把 PTY 尺寸同步成视图当前网格(防抖:旋转/捏合/键盘弹收连环触发)
    private func schedulePtySync() {
        resizeDebounce?.cancel()
        resizeDebounce = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, fitMode else { return }
            let grid = bridge.currentGrid()
            guard lastRequestedGrid?.cols != grid.cols || lastRequestedGrid?.rows != grid.rows else { return }
            lastRequestedGrid = grid
            client.requestResize(cols: grid.cols, rows: grid.rows)
        }
    }

    // MARK: - 生命周期

    private func activate() {
        bridge.client = client
        bridge.hapticsEnabled = bellHaptics
        bridge.fitMode = true
        bridge.setFont(size: CGFloat(fontSize))
        bridge.onGridChange = { _, _ in schedulePtySync() }
        bridge.onPinchScale = { scale, ended in
            if pinchBase == nil { pinchBase = fontSize }
            fontSize = ((pinchBase ?? fontSize) * scale).clamped(to: MobileSettingsKeys.fontSizeRange)
            if ended { pinchBase = nil }
        }
        client.onAttached = {
            bridge.reset()
            if let theme = client.theme { bridge.applyTheme(theme) }
            fitMode = true
            bridge.fitMode = true
            schedulePtySync()
        }
        client.onOutput = { bridge.feed($0) }
        client.onSessionEnded = { endedMessage = $0 }
        // Mac 端主动 resize = 有人在 Mac 前:切回镜像跟随,不跟真人抢尺寸
        client.onMacResize = { fitMode = false }
        if let theme = client.theme { bridge.applyTheme(theme) }
        client.attach(session.id)
        if let mac = store.selected { store.rememberSession(session.id, of: mac) }
        UIApplication.shared.isIdleTimerDisabled = keepAwake
    }

    /// iPad 双栏切换会话时,新视图的 activate 可能先于旧视图的 deactivate:
    /// 只有当自己仍是附着方时才解附/清回调,避免拆掉新会话的桥
    private func deactivate() {
        UIApplication.shared.isIdleTimerDisabled = false
        resizeDebounce?.cancel()
        guard client.attachedID == session.id else { return }
        client.detach()
        client.onAttached = nil
        client.onOutput = nil
        client.onSessionEnded = nil
        client.onMacResize = nil
    }

    // MARK: - 按键条

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
            ctrlArmed.toggle()
        } label: {
            Text("ctrl")
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(ctrlArmed ? Color.orange : Color(.secondarySystemBackground))
                .foregroundStyle(ctrlArmed ? .black : .primary)
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
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// 收起/呼出键盘:半屏键盘挡终端是手机第一痛点,给个一键开关
    private var keyboardToggle: some View {
        Button {
            if bridge.terminalView.isFirstResponder {
                _ = bridge.terminalView.resignFirstResponder()
            } else {
                _ = bridge.terminalView.becomeFirstResponder()
            }
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.system(size: 13))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color(.secondarySystemBackground))
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
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// 方向键长按连发(0.4s 起步,80ms/次)——TUI 菜单里单点太折磨
    private func repeatKeyButton(_ label: String, send: String) -> some View {
        RepeatKeyButton(label: label) { sendKey(send) }
    }

    private func sendKey(_ text: String) {
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
}

/// 按下即发一次,按住 0.4s 后以 80ms 间隔连发
private struct RepeatKeyButton: View {
    let label: String
    let fire: () -> Void

    @State private var pressed = false
    @State private var repeater: Task<Void, Never>?

    var body: some View {
        Text(label)
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(pressed ? Color(.systemGray3) : Color(.secondarySystemBackground))
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
