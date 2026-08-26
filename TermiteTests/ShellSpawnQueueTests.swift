import XCTest
@testable import Termite

/// 冷孵化排队的调度语义。并发代码没法靠肉眼审出来,这里把四条规则钉住:
/// 前台独享、后台限流、点开插队、排队中被关掉要能唤醒(否则 continuation 泄漏,
/// 那个 pane 永远起不来)。
@MainActor
final class ShellSpawnQueueTests: XCTestCase {

    /// 轮询等待:子任务要跑到挂起点才谈得上断言,固定 yield 次数不可靠
    private func waitUntil(_ message: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<5000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("超时:\(message)")
    }

    func testForegroundPaneBlocksBackgroundSpawns() async {
        let queue = ShellSpawnQueue(maxConcurrent: 2, slotTimeout: 600)
        let foreground = UUID()
        let background = UUID()
        queue.claimForeground(foreground)
        let task = Task { @MainActor in await queue.acquire(background, foreground: false) }
        await waitUntil("后台 pane 应在排队") { queue.waitingCountForTesting == 1 }
        XCTAssertEqual(queue.runningCountForTesting, 1, "前台没让出名额前后台不许起")
        queue.release(foreground)
        await task.value
        XCTAssertEqual(queue.runningCountForTesting, 1)
        XCTAssertEqual(queue.waitingCountForTesting, 0)
    }

    func testBackgroundSpawnsRespectConcurrencyLimit() async {
        let queue = ShellSpawnQueue(maxConcurrent: 2, slotTimeout: 600)
        let ids = (0..<3).map { _ in UUID() }
        let tasks = ids.map { id in Task { @MainActor in await queue.acquire(id, foreground: false) } }
        await waitUntil("应有两个在跑、一个在等") {
            queue.runningCountForTesting == 2 && queue.waitingCountForTesting == 1
        }
        queue.release(ids[0])
        for task in tasks { await task.value }
        XCTAssertEqual(queue.runningCountForTesting, 2)
        XCTAssertEqual(queue.waitingCountForTesting, 0)
    }

    /// 用户点开还在排队的标签:立刻放行,不受并发上限约束(人在等)
    func testPromoteBypassesConcurrencyLimit() async {
        let queue = ShellSpawnQueue(maxConcurrent: 1, slotTimeout: 600)
        let busy = UUID()
        let queued = UUID()
        await queue.acquire(busy, foreground: false)
        let task = Task { @MainActor in await queue.acquire(queued, foreground: false) }
        await waitUntil("第二个应在排队") { queue.waitingCountForTesting == 1 }
        queue.promote([queued])
        await task.value
        XCTAssertEqual(queue.runningCountForTesting, 2)
        XCTAssertEqual(queue.waitingCountForTesting, 0)
    }

    func testReleaseWakesUpPaneClosedWhileQueued() async {
        let queue = ShellSpawnQueue(maxConcurrent: 1, slotTimeout: 600)
        let busy = UUID()
        let doomed = UUID()
        queue.claimForeground(busy)
        let task = Task { @MainActor in await queue.acquire(doomed, foreground: false) }
        await waitUntil("被关的 pane 应在排队") { queue.waitingCountForTesting == 1 }
        queue.release(doomed)
        await task.value // 泄漏的话这里永远回不来
        XCTAssertEqual(queue.waitingCountForTesting, 0)
    }

    /// 不出声的 shell(卡在 rc 里等输入等)不能把队列堵死
    func testSlotTimeoutReleasesStuckSpawn() async {
        let queue = ShellSpawnQueue(maxConcurrent: 1, slotTimeout: 0.2)
        let mute = UUID()
        let next = UUID()
        queue.claimForeground(mute)
        let task = Task { @MainActor in await queue.acquire(next, foreground: false) }
        await waitUntil("后一个应在排队") { queue.waitingCountForTesting == 1 }
        await task.value
        XCTAssertGreaterThanOrEqual(queue.runningCountForTesting, 1)
    }
}
