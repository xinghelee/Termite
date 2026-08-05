import SwiftUI

/// 终端画面:上方终端(固定网格,超宽横向滚动),下方按键条。
/// 附着在 onAppear,离开自动解附;重连由 RemoteClient 兜底,重附后先重置再回放。
struct TerminalScreenView: View {
    let client: RemoteClient
    let session: RemoteSessionSummary

    @Environment(\.dismiss) private var dismiss
    @State private var bridge = TerminalBridge()
    @State private var ctrlArmed = false
    @State private var endedMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    TerminalCanvas(bridge: bridge)
                        .frame(width: bridge.contentSize.width, height: bridge.contentSize.height)
                }
                .onAppear {
                    bridge.fit(cols: client.gridCols, rows: client.gridRows, containerWidth: geo.size.width)
                }
                .onChange(of: client.gridCols) {
                    bridge.fit(cols: client.gridCols, rows: client.gridRows, containerWidth: geo.size.width)
                }
                .onChange(of: client.gridRows) {
                    bridge.fit(cols: client.gridCols, rows: client.gridRows, containerWidth: geo.size.width)
                }
                .onChange(of: geo.size.width) {
                    bridge.fit(cols: client.gridCols, rows: client.gridRows, containerWidth: geo.size.width)
                }
            }
            .background(Color(red: 0.078, green: 0.086, blue: 0.102))
            keyBar
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text("\(client.gridCols)×\(client.gridRows)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            bridge.client = client
            client.onAttached = { bridge.reset() }
            client.onOutput = { bridge.feed($0) }
            client.onSessionEnded = { endedMessage = $0 }
            client.attach(session.id)
            _ = bridge.terminalView.becomeFirstResponder()
        }
        .onDisappear {
            client.detach()
            client.onAttached = nil
            client.onOutput = nil
            client.onSessionEnded = nil
        }
        .alert("会话已结束", isPresented: .constant(endedMessage != nil)) {
            Button("好") {
                endedMessage = nil
                dismiss()
            }
        } message: {
            Text(endedMessage ?? "")
        }
        .overlay {
            if client.phase != .connected {
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

    // MARK: - 按键条

    private var keyBar: some View {
        HStack(spacing: 6) {
            keyButton("esc", send: "\u{1b}")
            keyButton("tab", send: "\t")
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
            keyButton("^C", send: "\u{03}")
            keyButton("↑", send: "\u{1b}[A")
            keyButton("↓", send: "\u{1b}[B")
            keyButton("←", send: "\u{1b}[D")
            keyButton("→", send: "\u{1b}[C")
            keyButton("⏎", send: "\r")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
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
