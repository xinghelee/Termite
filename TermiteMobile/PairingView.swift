import AVFoundation
import SwiftUI

/// 配对页:扫 Mac 设置页的二维码,或粘贴访问链接。
/// 二维码内容就是访问链接(http://ip:port/?t=token),两条路同一个解析器。
/// 首启全屏引导;已有 Mac 时作为「添加 Mac」sheet 复用。
struct PairingView: View {
    var isSheet = false

    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var manualText = ""
    @State private var showError = false
    @State private var cameraDenied = false
    @State private var discovery = LanDiscovery()
    @State private var pendingMac: LanDiscovery.Found?
    @State private var codeInput = ""
    @State private var redeeming = false
    @State private var codeError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    nearbyMacs
                    steps
                    scanner
                    form
                }
            }
            .navigationTitle(isSheet ? String(localized: "添加 Mac") : String(localized: "连接 Mac"))
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemGroupedBackground))
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { dismiss() }
                    }
                }
            }
        }
        .alert("链接无法识别", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("需要形如 http://192.168.x.x:9280/?t=xxxx 的链接,在 Mac 端 Termite 设置 → 远程 里获取")
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .alert("输入配对码", isPresented: Binding(
            get: { pendingMac != nil },
            set: { if !$0 { pendingMac = nil } }
        )) {
            TextField("6 位数字", text: $codeInput)
                .keyboardType(.numberPad)
            Button("连接") { redeemCode() }
                .disabled(codeInput.count != 6 || redeeming)
            Button("取消", role: .cancel) { pendingMac = nil }
        } message: {
            Text("在 \(pendingMac?.name ?? "Mac") 的 设置 → 远程 → 配对码 里生成")
        }
        .alert("配对失败", isPresented: Binding(
            get: { codeError != nil },
            set: { if !$0 { codeError = nil } }
        )) {
            Button("好", role: .cancel) { codeError = nil }
        } message: {
            Text(codeError ?? "")
        }
    }

    private func redeemCode() {
        guard let mac = pendingMac else { return }
        let code = codeInput
        pendingMac = nil
        redeeming = true
        Task {
            defer { redeeming = false }
            do {
                let granted = try await RemotePairing.redeem(code: code, at: mac.endpoint)
                let saved = store.adopt(Endpoint(host: granted.host, port: granted.port,
                                                 token: granted.token))
                // Mac 报的机器名比 IP 好认,配对成功顺手改过来
                store.rename(saved, to: granted.name)
                if isSheet { dismiss() }
            } catch RemotePairing.Failure.rejected {
                codeError = String(localized: "配对码不对或已失效,在 Mac 上重新生成一个")
            } catch {
                codeError = String(localized: "连不上这台 Mac,确认两边在同一个局域网")
            }
        }
    }

    // MARK: - 附近的 Mac(Bonjour 发现 + 6 位配对码)

    @ViewBuilder private var nearbyMacs: some View {
        if !discovery.macs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("附近的 Mac")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(discovery.macs) { mac in
                    Button {
                        pendingMac = mac
                        codeInput = ""
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(.tint)
                            Text(mac.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.secondarySystemGroupedBackground)))
                    }
                    .buttonStyle(.plain)
                }
                Text("在 Mac 的 设置 → 远程 里点「生成配对码」,把 6 位数字输进来")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Mac 上打开 Termite → 设置 → 远程", systemImage: "1.circle.fill")
            Label("打开「允许手机 / iPad 连接」", systemImage: "2.circle.fill")
            Label("扫描出现的二维码", systemImage: "3.circle.fill")
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var scanner: some View {
        ZStack {
            QRScannerView(
                onFound: { adopt($0) },
                onDenied: { cameraDenied = true }
            )
            if cameraDenied {
                VStack(spacing: 8) {
                    Image(systemName: "camera.on.rectangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("相机不可用,下方粘贴链接也能连")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.white.opacity(0.85), lineWidth: 2)
                    .frame(width: 180, height: 180)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("或粘贴访问链接")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                TextField("http://192.168.1.8:9280/?t=…", text: $manualText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("连接") {
                    adopt(manualText)
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func adopt(_ text: String) {
        guard let endpoint = Endpoint.parse(text) else {
            showError = true
            return
        }
        store.adopt(endpoint)
        if isSheet { dismiss() }
    }
}

// MARK: - 扫码

/// AVFoundation 二维码扫描(相机拒授权/模拟器无相机时回调 onDenied)
struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void
    let onDenied: () -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onFound = onFound
        controller.onDenied = onDenied
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onFound: ((String) -> Void)?
        var onDenied: (() -> Void)?
        private let session = AVCaptureSession()
        private var handled = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupSession()
                    } else {
                        self?.onDenied?()
                    }
                }
            }
        }

        private func setupSession() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                onDenied?()
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                onDenied?()
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)

            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.first { $0 is AVCaptureVideoPreviewLayer }?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !handled,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let text = object.stringValue else { return }
            // 只认能解析成配对端点的码,扫到别的二维码不动作
            guard Endpoint.parse(text) != nil else { return }
            handled = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            session.stopRunning()
            onFound?(text)
        }
    }
}
