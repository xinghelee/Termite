import CoreGraphics
import Foundation

/// 分屏方向
enum SplitAxis: Codable, Equatable { case horizontal, vertical }

/// 一个标签页内的分屏布局树:叶子是一个会话,分支是一次二分(可无限嵌套)。
/// ratio 是 first 侧所占比例(0-1),拖拽分隔条实时调整。
indirect enum PaneNode: Identifiable, Equatable {
    case leaf(UUID)                                              // sessionID(也作节点 id)
    case branch(id: UUID, axis: SplitAxis, ratio: Double, first: PaneNode, second: PaneNode)

    /// ratio 可拖拽范围(两侧至少留 12%)
    static let ratioRange = 0.12...0.88

    var id: UUID {
        switch self {
        case .leaf(let sid): return sid
        case .branch(let id, _, _, _, _): return id
        }
    }

    /// 所有叶子会话 id(展示顺序)
    func leafIDs() -> [UUID] {
        switch self {
        case .leaf(let sid): return [sid]
        case .branch(_, _, _, let a, let b): return a.leafIDs() + b.leafIDs()
        }
    }

    var firstLeaf: UUID {
        switch self {
        case .leaf(let sid): return sid
        case .branch(_, _, _, let a, _): return a.firstLeaf
        }
    }

    /// 把某个叶子替换成「原叶子 + 新叶子」的分支,实现在该 pane 上再分屏(嵌套)
    func splitting(leaf target: UUID, into newID: UUID, axis: SplitAxis, branchID: UUID, ratio: Double = 0.5) -> PaneNode {
        switch self {
        case .leaf(let sid):
            guard sid == target else { return self }
            return .branch(id: branchID, axis: axis, ratio: ratio, first: .leaf(sid), second: .leaf(newID))
        case .branch(let id, let ax, let r, let a, let b):
            return .branch(id: id, axis: ax, ratio: r,
                           first: a.splitting(leaf: target, into: newID, axis: axis, branchID: branchID, ratio: ratio),
                           second: b.splitting(leaf: target, into: newID, axis: axis, branchID: branchID, ratio: ratio))
        }
    }

    /// 移除某个叶子,并把其父分支塌缩为兄弟节点;整棵树空则返回 nil
    func removing(leaf target: UUID) -> PaneNode? {
        switch self {
        case .leaf(let sid):
            return sid == target ? nil : self
        case .branch(let id, let ax, let r, let a, let b):
            let na = a.removing(leaf: target)
            let nb = b.removing(leaf: target)
            switch (na, nb) {
            case (nil, nil): return nil
            case (nil, let x?): return x          // first 空 → 塌缩为 second
            case (let x?, nil): return x          // second 空 → 塌缩为 first
            case (let x?, let y?): return .branch(id: id, axis: ax, ratio: r, first: x, second: y)
            }
        }
    }

    /// 调整某个分支的分割比例(拖拽分隔条)
    func settingRatio(branch target: UUID, ratio newRatio: Double) -> PaneNode {
        switch self {
        case .leaf:
            return self
        case .branch(let id, let ax, let r, let a, let b):
            let clamped = min(max(newRatio, Self.ratioRange.lowerBound), Self.ratioRange.upperBound)
            return .branch(
                id: id, axis: ax, ratio: id == target ? clamped : r,
                first: a.settingRatio(branch: target, ratio: newRatio),
                second: b.settingRatio(branch: target, ratio: newRatio)
            )
        }
    }

    /// 找到某叶子的相邻叶子(关闭后把焦点交给它)
    func neighborLeaf(of target: UUID) -> UUID? {
        let leaves = leafIDs()
        guard let idx = leaves.firstIndex(of: target) else { return nil }
        if idx + 1 < leaves.count { return leaves[idx + 1] }
        if idx - 1 >= 0 { return leaves[idx - 1] }
        return nil
    }

    // MARK: - 方向导航(⌘⌥方向键)

    /// 各叶子的归一化布局矩形(0-1,y 向下增长与 VStack 一致;分隔条厚度忽略)
    func leafRects(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [UUID: CGRect] {
        switch self {
        case .leaf(let sid):
            return [sid: rect]
        case .branch(_, let axis, let ratio, let a, let b):
            var result: [UUID: CGRect]
            if axis == .horizontal {
                let width = rect.width * ratio
                result = a.leafRects(in: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height))
                result.merge(
                    b.leafRects(in: CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height))
                ) { current, _ in current }
            } else {
                let height = rect.height * ratio
                result = a.leafRects(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height))
                result.merge(
                    b.leafRects(in: CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height))
                ) { current, _ in current }
            }
            return result
        }
    }

    /// 按几何方向找相邻叶子:优先同轴距离最近且有垂直交叠的;打分确定性(不依赖字典遍历顺序)
    func neighborLeaf(of target: UUID, direction: PaneDirection) -> UUID? {
        let rects = leafRects()
        guard let current = rects[target] else { return nil }
        var best: (id: UUID, score: CGFloat)?
        for (id, rect) in rects where id != target {
            let axialDistance: CGFloat
            let perpendicularOverlap: CGFloat
            let perpendicularOffset: CGFloat
            switch direction {
            case .left:
                guard rect.midX < current.midX - 0.0001 else { continue }
                axialDistance = current.midX - rect.midX
                perpendicularOverlap = Self.overlap(rect.minY, rect.maxY, current.minY, current.maxY)
                perpendicularOffset = abs(rect.midY - current.midY)
            case .right:
                guard rect.midX > current.midX + 0.0001 else { continue }
                axialDistance = rect.midX - current.midX
                perpendicularOverlap = Self.overlap(rect.minY, rect.maxY, current.minY, current.maxY)
                perpendicularOffset = abs(rect.midY - current.midY)
            case .up:
                guard rect.midY < current.midY - 0.0001 else { continue }
                axialDistance = current.midY - rect.midY
                perpendicularOverlap = Self.overlap(rect.minX, rect.maxX, current.minX, current.maxX)
                perpendicularOffset = abs(rect.midX - current.midX)
            case .down:
                guard rect.midY > current.midY + 0.0001 else { continue }
                axialDistance = rect.midY - current.midY
                perpendicularOverlap = Self.overlap(rect.minX, rect.maxX, current.minX, current.maxX)
                perpendicularOffset = abs(rect.midX - current.midX)
            }
            let score = axialDistance * 100 + perpendicularOffset + (perpendicularOverlap > 0 ? 0 : 10_000)
            if best == nil || score < best!.score {
                best = (id, score)
            }
        }
        return best?.id
    }

    private static func overlap(_ aMin: CGFloat, _ aMax: CGFloat, _ bMin: CGFloat, _ bMax: CGFloat) -> CGFloat {
        max(0, min(aMax, bMax) - max(aMin, bMin))
    }
}

/// 分屏焦点导航方向
enum PaneDirection {
    case left, right, up, down
}

/// 标签页:一棵分屏树 + 当前聚焦的 pane
@MainActor
@Observable
final class PaneTab: Identifiable {
    let id = UUID()
    var root: PaneNode
    var focusedID: UUID
    /// 广播输入:开启后当前标签所有分屏 pane 同步接收键入
    var isBroadcasting = false
    /// 临时最大化的 pane(⇧⌘↩;nil = 正常分屏布局)
    var maximizedID: UUID?

    init(sessionID: UUID) {
        self.root = .leaf(sessionID)
        self.focusedID = sessionID
    }
}
