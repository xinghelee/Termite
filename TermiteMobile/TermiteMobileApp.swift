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
    }

    private func reconfigure() {
        guard let mac = store.selected, let endpoint = store.endpoint(for: mac) else {
            client.shutdown()
            return
        }
        client.shutdown()
        client.configure(endpoint)
    }
}
