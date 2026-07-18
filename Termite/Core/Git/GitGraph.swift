import Foundation

/// 提交图(SourceTree 式历史):git log 拓扑序 + 泳道分配

struct GraphCommitInfo: Identifiable, Equatable {
    let hash: String
    let shortHash: String
    let parents: [String]
    let author: String
    let relativeDate: String
    /// %D 解出的引用(HEAD -> main / origin/x / tag: v1)
    let refs: [String]
    let subject: String
    var id: String { hash }
}

/// 一行提交的绘图指令:dot 所在泳道 + 各类连线
struct GitGraphRow: Identifiable, Equatable {
    let commit: GraphCommitInfo
    /// 提交点所在泳道
    let lane: Int
    /// 本行需要的泳道数(画布宽度)
    let laneCount: Int
    /// 从上一行直通到下一行的泳道(竖线)
    let passThrough: [Int]
    /// 汇入本提交的泳道(上半段曲线 → dot)
    let mergesIn: [Int]
    /// 从本提交分出的泳道(dot → 下半段曲线;多父提交/首父已被别的泳道跟踪)
    let branchesOut: [Int]
    /// dot 上方有来线(本提交被上方某行期待;分支顶端没有)
    let hasTopLine: Bool
    /// dot 下方继续(首父占据本泳道)
    let continuesDown: Bool

    var id: String { commit.hash }
}

enum GitGraph {

    /// 解析 `git log --format=%H%x1f%h%x1f%P%x1f%an%x1f%cr%x1f%D%x1f%s`
    static func parseLog(_ text: String) -> [GraphCommitInfo] {
        text.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\u{1f}")
            guard parts.count >= 7 else { return nil }
            let refs = parts[5]
                .components(separatedBy: ", ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return GraphCommitInfo(
                hash: parts[0],
                shortHash: parts[1],
                parents: parts[2].isEmpty ? [] : parts[2].components(separatedBy: " "),
                author: parts[3],
                relativeDate: parts[4],
                refs: refs,
                subject: parts[6...].joined(separator: "\u{1f}")
            )
        }
    }

    /// 泳道分配(gitk/tig 经典算法):active[i] = 该泳道正在等待的提交 hash
    static func computeRows(_ commits: [GraphCommitInfo]) -> [GitGraphRow] {
        var active: [String?] = []
        var rows: [GitGraphRow] = []

        for commit in commits {
            let hasTopLine: Bool
            let lane: Int
            if let existing = active.firstIndex(of: commit.hash) {
                lane = existing
                hasTopLine = true
            } else if let empty = active.firstIndex(where: { $0 == nil }) {
                lane = empty
                active[empty] = commit.hash
                hasTopLine = false
            } else {
                lane = active.count
                active.append(commit.hash)
                hasTopLine = false
            }

            // 其它也在等本提交的泳道:汇入 dot 后关闭
            var mergesIn: [Int] = []
            for index in active.indices where index != lane && active[index] == commit.hash {
                mergesIn.append(index)
                active[index] = nil
            }

            // 现存的其它泳道:直通竖线
            let passThrough = active.indices.filter { $0 != lane && active[$0] != nil }

            var branchesOut: [Int] = []
            var continuesDown = false
            if let firstParent = commit.parents.first {
                if let existing = active.firstIndex(of: firstParent), existing != lane {
                    // 首父已有泳道在等:本泳道收口,曲线并入
                    branchesOut.append(existing)
                    active[lane] = nil
                } else {
                    active[lane] = firstParent
                    continuesDown = true
                }
            } else {
                active[lane] = nil // 根提交
            }
            for parent in commit.parents.dropFirst() {
                if let existing = active.firstIndex(of: parent) {
                    branchesOut.append(existing)
                } else if let empty = active.firstIndex(where: { $0 == nil }) {
                    active[empty] = parent
                    branchesOut.append(empty)
                } else {
                    active.append(parent)
                    branchesOut.append(active.count - 1)
                }
            }

            let involved = [lane] + passThrough + mergesIn + branchesOut
            rows.append(GitGraphRow(
                commit: commit,
                lane: lane,
                laneCount: max(involved.max()! + 1, active.count),
                passThrough: passThrough,
                mergesIn: mergesIn,
                branchesOut: branchesOut,
                hasTopLine: hasTopLine,
                continuesDown: continuesDown
            ))

            while active.last == nil, !active.isEmpty {
                active.removeLast()
            }
        }
        return rows
    }
}

extension GitService {
    /// 图形历史数据:全部引用、拓扑序(children 先于 parents,泳道算法的前提)
    static func graphLog(in directory: String, limit: Int = 300) async -> [GraphCommitInfo] {
        let format = "%H%x1f%h%x1f%P%x1f%an%x1f%cr%x1f%D%x1f%s"
        let text = await run(
            ["log", "--all", "--topo-order", "-\(limit)", "--format=\(format)"],
            in: directory
        ) ?? ""
        return GitGraph.parseLog(text)
    }
}
