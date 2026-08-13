import SwiftUI
import WebKit

/// 打开 Mac 转发出来的本机服务(模拟器调试 console、dev server 之类)。
///
/// 首次带 ?t= 进去,Mac 侧的代理验完就 302 到干净地址并种 cookie,
/// 之后页面里的绝对路径、WebSocket 都照常走 —— 所以这里只要一个普通 WKWebView。
struct ForwardWebView: View {
    let forward: RemoteForwardSummary
    let host: String
    let token: String

    @Environment(\.dismiss) private var dismiss
    @State private var loading = true

    private var url: URL? {
        URL(string: "http://\(host):\(forward.port)/?t=\(token)")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if let url {
                    WebContainer(url: url, loading: $loading)
                } else {
                    ContentUnavailableView("地址无效", systemImage: "link.badge.plus")
                }
                if loading {
                    ProgressView()
                }
            }
            .navigationTitle(forward.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct WebContainer: UIViewRepresentable {
    let url: URL
    @Binding var loading: Bool

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 调试 console 大多要 JS + 本地存储,按普通浏览器给足
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(loading: $loading)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let loading: Binding<Bool>

        init(loading: Binding<Bool>) {
            self.loading = loading
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loading.wrappedValue = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loading.wrappedValue = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            loading.wrappedValue = false
        }
    }
}
