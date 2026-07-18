import Foundation

/// 行级 diff(LCS):供「同一命令两次运行的输出对比」。
/// 先剥离相同前后缀缩小 DP 规模;规模仍超限时降级为整块替换。
enum LineDiff {
    enum Op: Equatable {
        case same(String)
        case added(String)
        case removed(String)
    }

    static func diff(old: [String], new: [String], maxLines: Int = 1500) -> [Op] {
        let a = Array(old.prefix(maxLines))
        let b = Array(new.prefix(maxLines))

        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        let coreA = Array(a[prefix..<(a.count - suffix)])
        let coreB = Array(b[prefix..<(b.count - suffix)])

        var ops: [Op] = a[0..<prefix].map { .same($0) }
        ops += diffCore(coreA, coreB)
        ops += a[(a.count - suffix)...].map { .same($0) }
        return ops
    }

    private static func diffCore(_ a: [String], _ b: [String]) -> [Op] {
        if a.isEmpty { return b.map { .added($0) } }
        if b.isEmpty { return a.map { .removed($0) } }
        // DP 规模上限(约 8MB int 表);中段完全不同的超大输出直接整块替换
        guard a.count * b.count <= 1_000_000 else {
            return a.map { .removed($0) } + b.map { .added($0) }
        }
        let n = a.count, m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                ops.append(.same(a[i])); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                ops.append(.removed(a[i])); i += 1
            } else {
                ops.append(.added(b[j])); j += 1
            }
        }
        while i < n { ops.append(.removed(a[i])); i += 1 }
        while j < m { ops.append(.added(b[j])); j += 1 }
        return ops
    }

    /// 变化统计(+新增 −删除)
    static func stats(_ ops: [Op]) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for op in ops {
            switch op {
            case .added: added += 1
            case .removed: removed += 1
            case .same: break
            }
        }
        return (added, removed)
    }
}
