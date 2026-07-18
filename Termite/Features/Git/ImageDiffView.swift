import SwiftUI

/// 图片改动预览:旧/新对照(文本 diff 对二进制无意义)。
/// 旧 = HEAD / 提交父版本,新 = 工作区 / 提交版本。
struct ImageDiffView: View {
    let change: GitFileChange
    let commitHash: String?
    let repoRoot: String

    @State private var oldImage: NSImage?
    @State private var newImage: NSImage?
    @State private var loaded = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        Group {
            if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 1) {
                    pane(title: String(localized: "旧"), image: oldImage)
                    Divider().overlay(theme.borderColor)
                    pane(title: String(localized: "新"), image: newImage)
                }
            }
        }
        .task(id: change.id) {
            await load()
            loaded = true
        }
    }

    private func pane(title: String, image: NSImage?) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let image {
                    Text("\(Int(image.size.width))×\(Int(image.size.height))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(checkerboard)
            } else {
                Text("无")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 透明图的棋盘格底
    private var checkerboard: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            for row in 0..<Int(size.height / cell + 1) {
                for column in 0..<Int(size.width / cell + 1) where (row + column) % 2 == 0 {
                    context.fill(
                        Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                        with: .color(Color.primary.opacity(0.05))
                    )
                }
            }
        }
    }

    private func load() async {
        // 新版本
        switch change.kind {
        case .committed:
            if let hash = commitHash, change.statusCode != "D",
               let data = await GitService.runData(["show", "\(hash):\(change.path)"], in: repoRoot) {
                newImage = NSImage(data: data)
            }
        default:
            if change.statusCode != "D" {
                newImage = NSImage(contentsOfFile: (repoRoot as NSString).appendingPathComponent(change.path))
            }
        }
        // 旧版本(新增/未跟踪没有旧版)
        guard change.statusCode != "A", change.statusCode != "?" else { return }
        let oldRef: String
        if change.kind == .committed, let hash = commitHash {
            oldRef = "\(hash)^:\(change.path)"
        } else {
            oldRef = "HEAD:\(change.path)"
        }
        if let data = await GitService.runData(["show", oldRef], in: repoRoot) {
            oldImage = NSImage(data: data)
        }
    }
}
