import CoreImage.CIFilterBuiltins
import SwiftUI

/// 设置 → 远程:手机/iPad 访问开关 + 配对二维码。
/// 定位 LAN / Tailscale 内网:不做公网穿透,链接带 token,扫码即配对
/// (iOS App 扫码直连;浏览器打开同一链接是应急 Web 入口)。
struct RemoteSettingsPage: View {
    @AppStorage(SettingsKeys.remoteAccessEnabled) private var enabled = false

    @State private var server = RemoteAccessServer.shared
    @State private var addresses: [RemoteAccessServer.AccessAddress] = []
    @State private var selectedIP: String?
    @State private var copiedIP: String?
    @State private var pairingCode: String?
    @State private var remaining = 0
    @State private var forwarder = RemoteForwarder.shared
    @State private var newPort = ""
    @State private var newLabel = ""

    var body: some View {
        SettingsPage {
            SettingsGroup("远程访问") {
                SettingsToggleRow(
                    title: "允许手机 / iPad 连接",
                    caption: "局域网或 Tailscale 内网直连本机,凭配对码访问",
                    isOn: $enabled
                )
            }
            SettingsFootnote("仅在受信任的网络里开启。链接含访问密钥,泄露等于交出本机终端;怀疑泄露立即重新生成。")

            if enabled {
                if let error = server.lastError {
                    SettingsPanel("状态") {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                }

                SettingsPanel("配对") {
                    pairingContent
                }
                SettingsFootnote("iOS 端 Termite 扫码即连;手机浏览器扫同一个码走网页版。二维码即访问链接,重新生成密钥后旧码作废。")

                SettingsPanel("本机端口转发") {
                    forwardContent
                }
                SettingsFootnote("把只监听 127.0.0.1 的本机服务给手机用:模拟器与 Mac 共用网络栈,跑在模拟器里的调试 console(SandboxServer 之类)在这里就是一个本机端口,转发出去手机上就能看画面、点按、滑动;dev server 同理。每条转发独占一个对外端口,首次带密钥打开后种 cookie,页面里的绝对路径和 WebSocket 都照常。")

                SettingsPanel("配对码") {
                    pairingCodeContent
                }
                SettingsFootnote("同一局域网里,iOS 端会自动发现这台 Mac,输入这 6 位即可配对(不用扫码)。5 分钟有效、用一次作废、错 5 次直接废掉;广播只含机器名和端口,密钥必须靠这道码换。")
            }
        }
        .onAppear {
            refreshAddresses()
            syncPairingCode()
        }
        .onChange(of: enabled) {
            if enabled {
                server.start()
                refreshAddresses()
            } else {
                server.stop()
            }
        }
    }

    // MARK: - 配对卡片

    @ViewBuilder private var pairingContent: some View {
        if addresses.isEmpty {
            Label("没有可用的网络接口(Wi-Fi / 网线 / Tailscale 都没连)", systemImage: "wifi.slash")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .top, spacing: 18) {
                qrCode
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(addresses) { address in
                        addressRow(address)
                    }
                    Divider()
                    HStack(spacing: 10) {
                        Button("重新生成密钥") {
                            server.regenerateToken()
                            restartServer()
                        }
                        .font(.system(size: 12))
                        Button {
                            refreshAddresses()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("刷新网络地址")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 本机端口转发

    @ViewBuilder private var forwardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(forwarder.forwards) { forward in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(forward.label)
                            .font(.system(size: 12))
                        // verbatim:端口号插 Int 会被格式化成「19,280」
                        Text(verbatim: "127.0.0.1:\(forward.target) → \(forward.listen)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Button {
                        let host = (selectedIP ?? addresses.first?.ip) ?? "127.0.0.1"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            forwarder.url(for: forward, host: host, token: server.token),
                            forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("拷贝转发链接")
                    Button {
                        forwarder.remove(forward)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("删除这条转发")
                }
            }
            if forwarder.forwards.isEmpty {
                Text("还没有转发。填本机服务的端口,比如模拟器里调试 console 的端口")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 8) {
                TextField("端口", text: $newPort)
                    .frame(width: 70)
                TextField("名字(可选)", text: $newLabel)
                    .frame(maxWidth: 180)
                Button("添加") {
                    guard let port = UInt16(newPort.trimmingCharacters(in: .whitespaces)) else { return }
                    forwarder.add(target: port, label: newLabel.trimmingCharacters(in: .whitespaces))
                    newPort = ""
                    newLabel = ""
                }
                .disabled(UInt16(newPort.trimmingCharacters(in: .whitespaces)) == nil)
                if let error = forwarder.lastError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            .font(.system(size: 12))
        }
    }

    // MARK: - 配对码(局域网自动发现用)

    @ViewBuilder private var pairingCodeContent: some View {
        HStack(spacing: 14) {
            if let code = pairingCode {
                Text(code.spacedDigits)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text(remaining > 0 ? "\(remaining) 秒后失效" : "已失效")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("作废") {
                    server.pairing.cancel()
                    syncPairingCode()
                }
                .font(.system(size: 12))
            } else {
                Text("需要时再生成,不用一直挂着")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("生成配对码") {
                    server.issuePairingCode()
                    syncPairingCode()
                }
                .font(.system(size: 12))
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            syncPairingCode()
        }
    }

    private func syncPairingCode() {
        let current = server.pairing.current
        pairingCode = current?.code
        remaining = current.map { max(0, Int($0.expiresAt.timeIntervalSinceNow)) } ?? 0
    }

    @ViewBuilder private var qrCode: some View {
        let ip = selectedIP ?? addresses.first?.ip
        if let ip, let image = Self.qrImage(server.accessURL(ip: ip)) {
            VStack(spacing: 6) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 148, height: 148)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white))
                Text(ip)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addressRow(_ address: RemoteAccessServer.AccessAddress) -> some View {
        HStack(spacing: 8) {
            Button {
                selectedIP = address.ip
            } label: {
                Image(systemName: (selectedIP ?? addresses.first?.ip) == address.ip
                      ? "qrcode" : "circle.dotted")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("二维码用这个地址")
            VStack(alignment: .leading, spacing: 1) {
                Text(address.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(server.accessURL(ip: address.ip))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(server.accessURL(ip: address.ip), forType: .string)
                copiedIP = address.ip
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if copiedIP == address.ip { copiedIP = nil }
                }
            } label: {
                Image(systemName: copiedIP == address.ip ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("拷贝链接")
        }
    }

    // MARK: - 工具

    private func refreshAddresses() {
        addresses = RemoteAccessServer.lanAddresses()
        if let selectedIP, !addresses.contains(where: { $0.ip == selectedIP }) {
            self.selectedIP = nil
        }
    }

    /// token/端口变更需要重启监听(握手校验的是启动时抓的值)
    private func restartServer() {
        guard server.isRunning else { return }
        server.stop()
        server.start()
    }

    private static func qrImage(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

private extension String {
    /// 6 位码分成两组三位,念给自己听或输进手机都不容易串行
    var spacedDigits: String {
        count == 6 ? "\(prefix(3)) \(suffix(3))" : self
    }
}
