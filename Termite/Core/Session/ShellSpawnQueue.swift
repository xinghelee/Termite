import Foundation

/// shell 冷孵化排队。
///
/// 拖慢「重启电脑后第一次启动」的既不是 app(到首帧 0.32s)也不是守护进程握手,
/// 而是恢复时几十个 shell 同时 fork/exec 再各跑一遍 rc:按老的 0.3+0.15n 阶梯,
/// 每个 shell 实际要好几秒,于是峰值二十几个并发——实测 33 个 zsh 这样起,
/// 选中标签自己从独占时的 1.07s 被拖到 2.01s,整波 10.4s、内核态 50s。
/// 刚开机页缓存全冷时这一项还要再翻几倍,这就是「卡」的来源。
///
/// 规则:
/// - 可见 pane 先独享机器,后台 pane 一律等它出提示符(或 4 秒兜底)
/// - 其余排队,同时最多 `maxConcurrent` 个
/// - 用户点开还在排队的标签,它立刻拿到名额(不受并发上限约束——人在等)
/// - 名额在 shell 吐出第一段输出(≈提示符)时归还;不出声的有兜底超时,堵不死队列
///
/// 只管冷孵化:接回守护进程里的活会话(attach)不进队列,那条路本来就不花钱。
@MainActor
final class ShellSpawnQueue {
    static let shared = ShellSpawnQueue()

    /// 后台 pane 的并发上限
    private let maxConcurrent: Int
    /// 单个名额的最长持有时间:shell 迟迟不出声也得把位置让出来
    private let slotTimeout: TimeInterval

    init(maxConcurrent: Int = 3, slotTimeout: TimeInterval = 4) {
        self.maxConcurrent = maxConcurrent
        self.slotTimeout = slotTimeout
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var waiting: [Waiter] = []
    private var running: Set<UUID> = []
    /// 正在冷启动的可见 pane:非空时后台 pane 全部让路
    private var foreground: Set<UUID> = []

    /// 取一个孵化名额。前台(可见/用户新建)pane 立即拿到,后台 pane 可能挂起等待
    func acquire(_ id: UUID, foreground isForeground: Bool) async {
        if isForeground {
            claimForeground(id)
            return
        }
        if canStartBackground {
            grant(id)
            return
        }
        await withCheckedContinuation { continuation in
            waiting.append(Waiter(id: id, continuation: continuation))
        }
    }

    /// 同步占下前台名额(本地直连路径不经过 await,但后台 pane 仍要为它让路)
    func claimForeground(_ id: UUID) {
        foreground.insert(id)
        grant(id)
    }

    /// shell 出了第一段输出 / 会话提前关掉:归还名额,放下一个进来
    func release(_ id: UUID) {
        foreground.remove(id)
        if running.remove(id) == nil, let index = waiting.firstIndex(where: { $0.id == id }) {
            // 还没轮到就被关掉:唤醒它自己去发现 didShutdown
            waiting.remove(at: index).continuation.resume()
        }
        pump()
    }

    /// 用户点开了还在排队的 pane:立刻放行(人在等,不受并发上限约束)
    func promote(_ ids: [UUID]) {
        for id in ids {
            guard let index = waiting.firstIndex(where: { $0.id == id }) else { continue }
            let waiter = waiting.remove(at: index)
            grant(waiter.id)
            waiter.continuation.resume()
        }
    }

    private var canStartBackground: Bool {
        foreground.isEmpty && running.count < maxConcurrent
    }

    private func grant(_ id: UUID) {
        running.insert(id)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.slotTimeout ?? 4))
            self?.release(id)
        }
    }

    private func pump() {
        while canStartBackground, !waiting.isEmpty {
            let next = waiting.removeFirst()
            grant(next.id)
            next.continuation.resume()
        }
    }

    // MARK: - 测试探针

    var runningCountForTesting: Int { running.count }
    var waitingCountForTesting: Int { waiting.count }
}
