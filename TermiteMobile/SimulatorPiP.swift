import SwiftUI

/// 终端界面上的模拟器实时浮窗:跟 Claude 对话的同时看着 UI 变。
///
/// 手感取自系统画中画:拖动跟手、松手吸附到最近的角、双指缩放改大小、
/// 点一下展开全屏。位置和大小记在 AppStorage 里,下次打开还在原地。
struct SimulatorPiP: View {
    let client: MirrorClient
    /// 终端可用区域,浮窗吸附在它的四角内
    let bounds: CGSize
    let onExpand: () -> Void
    let onClose: () -> Void

    @AppStorage("mirror.pip.corner") private var cornerRaw = Corner.bottomTrailing.rawValue
    @AppStorage("mirror.pip.width") private var storedWidth = 132.0

    @State private var drag = CGSize.zero
    @State private var pinchBase: Double?

    private enum Corner: Int {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        static func nearest(to point: CGPoint, in size: CGSize) -> Corner {
            let left = point.x < size.width / 2
            let top = point.y < size.height / 2
            return switch (top, left) {
            case (true, true): .topLeading
            case (true, false): .topTrailing
            case (false, true): .bottomLeading
            case (false, false): .bottomTrailing
            }
        }
    }

    private var corner: Corner { Corner(rawValue: cornerRaw) ?? .bottomTrailing }

    private var aspect: CGFloat {
        guard client.frameSize.height > 0 else { return 9.0 / 19.5 }
        return client.frameSize.width / client.frameSize.height
    }

    private var size: CGSize {
        let width = min(max(storedWidth, 90), max(bounds.width - 32, 120))
        return CGSize(width: width, height: width / max(aspect, 0.2))
    }

    private var origin: CGPoint {
        let inset: CGFloat = 12
        let x = switch corner {
        case .topLeading, .bottomLeading: inset
        case .topTrailing, .bottomTrailing: bounds.width - size.width - inset
        }
        let y = switch corner {
        case .topLeading, .topTrailing: inset
        case .bottomLeading, .bottomTrailing: bounds.height - size.height - inset
        }
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
            .overlay(alignment: .topTrailing) { closeButton }
            .position(x: origin.x + size.width / 2 + drag.width,
                      y: origin.y + size.height / 2 + drag.height)
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)
            .onTapGesture(perform: onExpand)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: cornerRaw)
            .animation(.easeOut(duration: 0.15), value: size)
    }

    @ViewBuilder private var content: some View {
        if let frame = client.frame {
            Image(uiImage: frame)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
        } else {
            VStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("等待画面")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(5)
                .background(Circle().fill(.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .padding(5)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                // 松手吸到最近的角:小屏上自由摆放很容易挡住输入区
                let center = CGPoint(x: origin.x + size.width / 2 + value.translation.width,
                                     y: origin.y + size.height / 2 + value.translation.height)
                cornerRaw = Corner.nearest(to: center, in: bounds).rawValue
                drag = .zero
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchBase == nil { pinchBase = storedWidth }
                storedWidth = ((pinchBase ?? storedWidth) * value.magnification)
                    .clamped(to: 90...max(bounds.width - 32, 120))
            }
            .onEnded { _ in pinchBase = nil }
    }
}

/// 全屏查看:横竖屏都铺满,角上显示实测帧率
struct SimulatorFullScreen: View {
    let client: MirrorClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let frame = client.frame {
                    Image(uiImage: frame)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .overlay(alignment: .topTrailing) {
                Text(verbatim: "\(Int(client.fps)) fps")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.4)))
                    .padding(12)
            }
            .navigationTitle(client.devices.first { $0.id == client.attachedID }?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}
