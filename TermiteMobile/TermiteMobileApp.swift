import SwiftUI

/// Termite iOS:Mac 端 Termite 的远程终端(LAN/Tailscale 内网直连)。
/// 未配对显示扫码引导;配好即连,进会话仪表盘。
@main
struct TermiteMobileApp: App {
    @State private var store = ConnectionStore()
    @State private var client = RemoteClient()

    var body: some Scene {
        WindowGroup {
            RootView(client: client)
                .environment(store)
                .preferredColorScheme(.dark)
                // Termite 品牌琥珀:芯片/按钮/选中态统一(终端页内再被主题强调色覆盖)
                .tint(Color(red: 0.91, green: 0.64, blue: 0.24))
        }
    }
}

private struct RootView: View {
    @Environment(ConnectionStore.self) private var store
    let client: RemoteClient

    var body: some View {
        Group {
            if store.macs.isEmpty {
                PairingView()
            } else {
                MainView(client: client)
            }
        }
        .onChange(of: store.selectedID, initial: true) {
            reconfigure()
        }
        .onChange(of: store.macs) {
            // 重新配对同一台 Mac(token 换新)后立刻用新凭据重连
            reconfigure()
        }
        // termite://pair?host=..&port=..&t=..:点链接一键配对(AirDrop/信息里发链接可直达)
        .onOpenURL { url in
            if let endpoint = Endpoint.parse(url.absoluteString) {
                store.adopt(endpoint)
            }
        }
    }

    private func reconfigure() {
        guard let mac = store.selected else {
            client.shutdown()
            return
        }
        guard let endpoint = store.endpoint(for: mac) else {
            // Keychain 里没有这台 Mac 的密钥(换机恢复/被清):别卡在「连接中」,
            // 直接移除这条残缺配对,回到扫码引导给用户出路
            client.shutdown()
            store.remove(mac)
            return
        }
        client.shutdown()
        client.configure(endpoint)
    }
}
