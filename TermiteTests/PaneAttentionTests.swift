import XCTest
@testable import Termite

/// pane 注意力:静默启发式与注意力状态的纯逻辑测试
/// (bell / 焦点消解等依赖真实会话与窗口,由人工验收)
final class PaneAttentionTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    /// agent 工作模式:持续刷屏 6s 后静默 → 达到判定条件
    func testBusyStreakThenSilenceQualifies() {
        var h = SilenceHeuristic()
        for i in 0...12 {
            h.recordOutput(at: t0.addingTimeInterval(Double(i) * 0.5))
        }
        XCTAssertTrue(h.hadBusyStreak())
        // 静默 6s 后 remainingSilence 归零
        let lastOutput = t0.addingTimeInterval(6)
        XCTAssertGreaterThan(h.remainingSilence(at: lastOutput.addingTimeInterval(3))!, 0)
        XCTAssertLessThanOrEqual(h.remainingSilence(at: lastOutput.addingTimeInterval(6))!, 0)
    }

    /// vim 模式:偶发短输出(间隔超过 streakGap)不累积成「在干活」
    func testSparseOutputDoesNotBuildStreak() {
        var h = SilenceHeuristic()
        for i in 0..<5 {
            h.recordOutput(at: t0.addingTimeInterval(Double(i) * 3))
        }
        XCTAssertFalse(h.hadBusyStreak())
    }

    /// 短促输出(不足 minStreak)后的静默不算
    func testShortBurstDoesNotQualify() {
        var h = SilenceHeuristic()
        h.recordOutput(at: t0)
        h.recordOutput(at: t0.addingTimeInterval(1))
        h.recordOutput(at: t0.addingTimeInterval(2))
        XCTAssertFalse(h.hadBusyStreak())
    }

    /// 间隔后重新持续输出,streak 从新一段重新计
    func testStreakRestartsAfterGap() {
        var h = SilenceHeuristic()
        for i in 0...12 {
            h.recordOutput(at: t0.addingTimeInterval(Double(i) * 0.5))
        }
        XCTAssertTrue(h.hadBusyStreak())
        // 静默 10s 后来一条孤立输出:旧 streak 作废
        h.recordOutput(at: t0.addingTimeInterval(16))
        XCTAssertFalse(h.hadBusyStreak())
        // 再持续输出 5s 以上,重新满足
        for i in 0...11 {
            h.recordOutput(at: t0.addingTimeInterval(16 + Double(i) * 0.5))
        }
        XCTAssertTrue(h.hadBusyStreak())
        XCTAssertEqual(h.streakStart, t0.addingTimeInterval(16))
    }

    /// 从未有输出:没有静默判定点
    func testRemainingSilenceNilWithoutOutput() {
        let h = SilenceHeuristic()
        XCTAssertNil(h.remainingSilence(at: t0))
        XCTAssertFalse(h.hadBusyStreak())
    }

    /// 首条输出即形成 streak 起点(第二条在 gap 内时向前补齐)
    func testStreakStartAnchorsToFirstOutput() {
        var h = SilenceHeuristic()
        h.recordOutput(at: t0)
        h.recordOutput(at: t0.addingTimeInterval(1))
        XCTAssertEqual(h.streakStart, t0)
        h.recordOutput(at: t0.addingTimeInterval(6))  // 超过 gap,新起点
        XCTAssertEqual(h.streakStart, t0.addingTimeInterval(6))
    }

    func testAttentionStateHelpers() {
        XCTAssertFalse(PaneAttention.none.isActive)
        XCTAssertFalse(PaneAttention.none.needsInput)
        XCTAssertTrue(PaneAttention.needsInput(fromBell: true).needsInput)
        XCTAssertTrue(PaneAttention.needsInput(fromBell: false).isActive)
        XCTAssertFalse(PaneAttention.finished(failed: false).needsInput)
        XCTAssertTrue(PaneAttention.finished(failed: true).isActive)
    }
}
