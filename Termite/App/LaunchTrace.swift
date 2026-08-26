import Darwin
import Foundation
import os

/// 启动耗时埋点:从 exec 到「选中 pane 出第一屏」的分段计时,一次启动只打一行。
///
/// 「启动慢」每次的成因都不同——app 冷启动、守护进程握手(活着 vs 冷拉起,新构建
/// 还要过 Gatekeeper 评估)、shell 自己的 rc 初始化,三段占比天差地别。靠感觉调
/// 只会改错地方,这里把分段钉死在日志里:
///
///     log show --last 10m --style compact --predicate 'subsystem == "com.termite.app"'
///
/// 里程碑不再进来 2 秒后自动汇总,此后 mark 全部空转(不留常驻开销)。
@MainActor
enum LaunchTrace {
    private static let log = Logger(subsystem: "com.termite.app", category: "launch")

    /// 进程 exec 的墙钟时刻:含 dyld 与 main 之前的一切,比 App.init 起算诚实
    private static let processStart = execTime()
    private static var marks: [(name: String, label: String, elapsed: TimeInterval)] = []
    private static var summary: Task<Void, Never>?
    private static var finished = false

    /// 还在采集期。热路径(每段 PTY 输出)先问这个再 mark,免得白跑一趟
    static var isActive: Bool { !finished }

    /// 记一个里程碑。同名只留第一次:恢复期几十个会话都会撞同一个点,
    /// 要的是「第一个到达」的时刻
    static func mark(_ name: String, _ detail: String? = nil) {
        guard !finished, !marks.contains(where: { $0.name == name }) else { return }
        let label = detail.map { "\(name)(\($0))" } ?? name
        marks.append((name, label, Date().timeIntervalSince1970 - processStart))
        summary?.cancel()
        summary = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    private static func flush() {
        guard !finished, !marks.isEmpty else { return }
        finished = true
        let line = marks.map { "\($0.label)=\(Int(($0.elapsed * 1000).rounded()))ms" }
            .joined(separator: " ")
        marks = []
        summary = nil
        log.notice("启动耗时(自 exec): \(line, privacy: .public)")
    }

    /// 本进程的 exec 时刻(sysctl 的 p_starttime 是墙钟 timeval)
    private static func execTime() -> TimeInterval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return Date().timeIntervalSince1970
        }
        let started = info.kp_proc.p_starttime
        return TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000
    }
}
