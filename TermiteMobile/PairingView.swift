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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                steps
                scanner
                form
                Spacer(minLength: 0)
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
