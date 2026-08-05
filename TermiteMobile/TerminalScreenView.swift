import SwiftUI

/// 终端画面:iPhone 栈式推入 / iPad 双栏详情通用。
/// 尺寸两种模式:镜像 Mac 网格(默认,可读字号+横向滚动)/「适配手机宽度」
/// (tmux 语义,PTY 临时改成本机列数,Mac 端 resize 自动夺回)。
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
    /// 适配手机宽度(会话内状态;Mac 端 resize 会把它顶回镜像模式)
    @State private var fitWidth = false
    @State private var terminalSize = CGSize.zero
    @State private var resizeDebounce: Task<Void, Never>?

    private var themeBackground: Color {
        client.theme.map { Color(UIColor(hex: $0.background)) } ?? Color(red: 0.078, green: 0.086, blue: 0.102)
    }

    var body: some View {
        VStack(spacing: 0) {
            terminalArea
            keyBar
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onAppear { activate() }
        .onDisappear { deactivate() }
        .onChange(of: keepAwake) { UIApplication.shared.isIdleTimerDisabled = keepAwake }
        .onChange(of: bellHaptics) { bridge.hapticsEnabled = bellHaptics }
        // Mac 端 resize 夺回尺寸:退出适配模式,跟随 Mac 网格
        .onChange(of: client.gridCols) { fitWidth = false; relayout() }
        .onChange(of: client.gridRows) { fitWidth = false; relayout() }
        .onChange(of: fontSize) { relayout() }
        .onChange(of: fitWidth) { relayout() }
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

    // MARK: - 终端区

    private var terminalArea: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                TerminalCanvas(bridge: bridge)
                    .frame(width: bridge.contentSize.width, height: bridge.contentSize.height)
            }
            .onAppear {
                terminalSize = geo.size
                relayout()
            }
            .onChange(of: geo.size) {
                terminalSize = geo.size
                relayout()
            }
        }
        .background(themeBackground)
        // 捏合调字号,落点持久化;适配模式下列数随字号联动重算
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in
                    if pinchBase == nil { pinchBase = fontSize }
                    fontSize = ((pinchBase ?? fontSize) * scale).clamped(to: MobileSettingsKeys.fontSizeRange)
                }
                .onEnded { _ in pinchBase = nil }
        )
    }

    /// 当前生效网格:适配模式用本机算出的列数,镜像模式跟 Mac
    private func relayout() {
        guard terminalSize.width > 40 else { return }
        if fitWidth {
            let grid = bridge.gridThatFits(size: terminalSize, fontSize: CGFloat(fontSize))
            bridge.layout(cols: grid.cols, rows: grid.rows, fontSize: CGFloat(fontSize))
            // SIGWINCH 防抖:捏合/旋转中不要连环轰炸 PTY
            resizeDebounce?.cancel()
            resizeDebounce = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                client.requestResize(cols: grid.cols, rows: grid.rows)
            }
        } else {
            bridge.layout(cols: client.gridCols, rows: client.gridRows, fontSize: CGFloat(fontSize))
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                toggleFit()
            } label: {
                Image(systemName: fitWidth
                      ? "rectangle.compress.vertical" : "iphone.sizes")
            }
            .help(fitWidth ? "恢复 Mac 端尺寸" : "适配手机宽度")
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
                Image(systemName: "textformat.size")
            }
        }
    }

    private var gridLabel: String {
        let grid = fitWidth
            ? bridge.gridThatFits(size: terminalSize, fontSize: CGFloat(fontSize))
            : (cols: client.gridCols, rows: client.gridRows)
        return "\(grid.cols)×\(grid.rows) · \(Int(fontSize))pt"
    }

    private func toggleFit() {
        if fitWidth {
            fitWidth = false
            // 显式还给 Mac(不等解附):按 Mac 网格请求一次
            client.requestResize(cols: client.gridCols, rows: client.gridRows)
        } else {
            fitWidth = true
        }
    }

    // MARK: - 生命周期

    private func activate() {
        bridge.client = client
        bridge.hapticsEnabled = bellHaptics
        client.onAttached = {
            bridge.reset()
            if let theme = client.theme { bridge.applyTheme(theme) }
            fitWidth = false
            relayout()
        }
        client.onOutput = { bridge.feed($0) }
        client.onSessionEnded = { endedMessage = $0 }
        if let theme = client.theme { bridge.applyTheme(theme) }
        client.attach(session.id)
        if let mac = store.selected { store.rememberSession(session.id, of: mac) }
        UIApplication.shared.isIdleTimerDisabled = keepAwake
        _ = bridge.terminalView.becomeFirstResponder()
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
    }

    // MARK: - 按键条

    private var keyBar: some View {
        HStack(spacing: 6) {
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
        .background(.bar)
    }

    private var ctrlButton: some View {
        Button {
            ctrlArmed.toggle()
        } label: {
            Text("ctrl")
                .font(.system(size: 13, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
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
                .font(.system(size: 13, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
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
            .font(.system(size: 13, design: .monospaced))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
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
