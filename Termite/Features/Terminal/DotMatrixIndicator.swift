import SwiftUI

/// 点阵运行指示:一小块 LED 矩阵,暗点铺底、亮点带拖尾地走。
/// 取代标签 chip / 状态栏里的系统菊花——菊花只有「在转」一种表情,
/// 点阵能用图案区分「命令在跑」和「agent 在干活」。
struct DotMatrixIndicator: View {
    enum Pattern {
        /// 彗星沿外圈绕行:普通命令在跑
        case orbit
        /// 从中心向外一圈圈荡开:agent 正在产出
        case ripple
    }

    var pattern: Pattern = .orbit
    var tint: Color = .accentColor
    /// 整块边长(pt)
    var side: CGFloat = 11
    /// 每边点数;chip 里 4 是能看清图案的上限,大尺寸可以给到 6–8
    var grid: Int = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // 20fps 足够点阵这种离散图案;减弱动态效果时停在一帧静态图
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0.35 : context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                draw(in: &ctx, size: size, time: time)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let n = max(grid, 2)
        let cell = min(size.width, size.height) / CGFloat(n)
        let dot = cell * 0.74
        let inset = (cell - dot) / 2
        // 深色底上亮点头部提向白色才有「发光」感;浅色底提白等于消失,只用本色
        let glow: Color = colorScheme == .dark ? .white : tint

        for row in 0..<n {
            for col in 0..<n {
                let level = intensity(row: row, col: col, n: n, time: time)
                let rect = CGRect(x: CGFloat(col) * cell + inset, y: CGFloat(row) * cell + inset,
                                  width: dot, height: dot)
                let path = Path(ellipseIn: rect)
                ctx.fill(path, with: .color(tint.opacity(0.2 + 0.8 * level)))
                if level > 0.72 {
                    ctx.fill(path, with: .color(glow.opacity((level - 0.72) / 0.28 * 0.85)))
                }
            }
        }
    }

    /// 某个点此刻的亮度 0…1(0 = 只剩铺底的暗点)
    private func intensity(row: Int, col: Int, n: Int, time: TimeInterval) -> Double {
        switch pattern {
        case .orbit:
            guard let index = Self.perimeterIndex(row: row, col: col, n: n) else { return 0 }
            let count = Double(4 * (n - 1))
            let head = (time * count / 1.15).truncatingRemainder(dividingBy: count)
            var behind = (head - Double(index)).truncatingRemainder(dividingBy: count)
            if behind < 0 { behind += count }
            let tail = count * 0.55
            return behind < tail ? pow(1 - behind / tail, 1.6) : 0
        case .ripple:
            let center = Double(n - 1) / 2
            let dx = Double(col) - center, dy = Double(row) - center
            let radius = (dx * dx + dy * dy).squareRoot() / (center * 2.0.squareRoot())
            let wave = 0.5 + 0.5 * sin(2 * .pi * (time / 1.3 - radius * 0.85))
            return pow(wave, 2.2)
        }
    }

    /// 外圈点的顺时针序号(左上角起);内部点返回 nil
    static func perimeterIndex(row: Int, col: Int, n: Int) -> Int? {
        let last = n - 1
        if row == 0 { return col }
        if col == last { return last + row }
        if row == last { return 2 * last + (last - col) }
        if col == 0 { return 3 * last + (last - row) }
        return nil
    }
}

/// 会话的运行指示:把「命令在跑 / 长驻 / agent 正在产出」三种情况收成一处,
/// 标签 chip 与状态栏共用,两边不会各说各话。
struct SessionRunIndicator: View {
    let session: TerminalSession
    var side: CGFloat = 11

    var body: some View {
        if session.longRunningCommand {
            if session.isAgentProgram, session.outputBusy {
                // 长驻的 agent(claude 一开就是几小时):只在它真的在刷输出时才动
                DotMatrixIndicator(pattern: .ripple, tint: ThemeStore.shared.current.accentColor, side: side)
            } else {
                // ssh / dev server 这类长驻进程:永动太吵,降级为静态绿点
                Circle()
                    .fill(Color.green.opacity(0.8))
                    .frame(width: 6, height: 6)
                    .frame(width: side, height: side)
                    .help("长时间运行中")
            }
        } else {
            DotMatrixIndicator(pattern: .orbit, tint: ThemeStore.shared.current.accentColor, side: side)
        }
    }
}
