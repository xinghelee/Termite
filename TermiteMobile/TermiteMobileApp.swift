import SwiftUI

/// Termite iOS:Mac 端 Termite 的远程终端(LAN/Tailscale 内网直连)。
/// 未配对显示扫码页;配好即连,进会话列表。
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
            if store.endpoint == nil {
                PairingView()
            } else {
                SessionListView(client: client)
            }
        }
        .onChange(of: store.endpoint, initial: true) {
            if let endpoint = store.endpoint {
                client.configure(endpoint)
            } else {
                client.shutdown()
            }
        }
        // token 被拒(Mac 端重新生成过):回配对页重扫
        .onChange(of: client.phase) {
            if client.phase == .denied {
                store.endpoint = nil
            }
        }
    }
}
