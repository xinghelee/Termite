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
            }
        }
        .onAppear {
            refreshAddresses()
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
