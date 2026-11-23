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

    /// 包含 target、轴向为 axis 的最内层分支(键盘调大小:动离焦点最近的那条分隔条)
    func nearestBranch(containing target: UUID, axis: SplitAxis) -> (id: UUID, ratio: Double)? {
        guard case .branch(let id, let ax, let r, let a, let b) = self else { return nil }
        let inFirst = a.leafIDs().contains(target)
        guard inFirst || b.leafIDs().contains(target) else { return nil }
        if let deeper = (inFirst ? a : b).nearestBranch(containing: target, axis: axis) { return deeper }
        return ax == axis ? (id, r) : nil
    }

    /// 按方向键移动分隔条:方向即分隔条移动方向(同 tmux),每次 step;无对应轴向的分隔条返回 nil
    func resizing(leaf target: UUID, direction: PaneDirection, step: Double = 0.05) -> PaneNode? {
        let axis: SplitAxis = (direction == .left || direction == .right) ? .horizontal : .vertical
        guard let branch = nearestBranch(containing: target, axis: axis) else { return nil }
        let delta = (direction == .right || direction == .down) ? step : -step
        return settingRatio(branch: branch.id, ratio: branch.ratio + delta)
    }

    /// 把某个叶子换成「该叶子 + 另一棵子树」的分支:拖标签到 pane 边缘时,整个标签贴到那一侧
    func inserting(_ subtree: PaneNode, at target: UUID, edge: PaneDropEdge, branchID: UUID = UUID()) -> PaneNode {
        switch self {
        case .leaf(let sid):
            guard sid == target else { return self }
            switch edge {
            case .left: return .branch(id: branchID, axis: .horizontal, ratio: 0.5, first: subtree, second: self)
            case .right: return .branch(id: branchID, axis: .horizontal, ratio: 0.5, first: self, second: subtree)
            case .top: return .branch(id: branchID, axis: .vertical, ratio: 0.5, first: subtree, second: self)
            case .bottom: return .branch(id: branchID, axis: .vertical, ratio: 0.5, first: self, second: subtree)
            }
        case .branch(let id, let ax, let r, let a, let b):
            return .branch(id: id, axis: ax, ratio: r,
                           first: a.inserting(subtree, at: target, edge: edge, branchID: branchID),
                           second: b.inserting(subtree, at: target, edge: edge, branchID: branchID))
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

// MARK: - 像素布局(扁平化渲染)

/// 一条分隔条的位置:rect 是命中区,span 是所属分支的整块区域(拖动时据此换算 ratio)
struct PaneDividerSlot: Identifiable, Equatable {
    let id: UUID
    let axis: SplitAxis
    let rect: CGRect
    let span: CGRect
    let dividerThickness: CGFloat

    /// 指针在分支轴向上的位置 → 新 ratio(与分支内 first 长度 = (总长 - 分隔条) × ratio 对应)
    func ratio(at point: CGPoint) -> Double? {
        let total = (axis == .horizontal ? span.width : span.height) - dividerThickness
        guard total > 0 else { return nil }
        let position = axis == .horizontal ? point.x - span.minX : point.y - span.minY
        return Double(position / total)
    }
}

/// 整棵树在像素空间的扁平布局:叶子与分隔条各一张平铺列表。
/// 扁平渲染让叶子在树重组(分屏/合并/关闭)时保持身份,frame 才能连续动画
struct PaneLayoutFrames: Equatable {
    var leaves: [(id: UUID, rect: CGRect)] = []
    var dividers: [PaneDividerSlot] = []

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dividers == rhs.dividers
            && lhs.leaves.map(\.id) == rhs.leaves.map(\.id)
            && lhs.leaves.map(\.rect) == rhs.leaves.map(\.rect)
    }

    func rect(of leaf: UUID) -> CGRect? {
        leaves.first { $0.id == leaf }?.rect
    }
}

extension PaneNode {
    /// 按像素算出每个叶子与分隔条的矩形;分隔条占 dividerThickness,first 侧 = (总长 - 分隔条) × ratio
    func layoutFrames(in rect: CGRect, dividerThickness: CGFloat) -> PaneLayoutFrames {
        var frames = PaneLayoutFrames()
        collectFrames(in: rect, dividerThickness: dividerThickness, into: &frames)
        return frames
    }

    private func collectFrames(in rect: CGRect, dividerThickness: CGFloat, into frames: inout PaneLayoutFrames) {
        switch self {
        case .leaf(let sid):
            frames.leaves.append((sid, rect))
        case .branch(let id, let axis, let ratio, let a, let b):
            let length = axis == .horizontal ? rect.width : rect.height
            let total = max(0, length - dividerThickness)
            let firstLength = max(0, total * ratio)
            let secondLength = max(0, total - firstLength)
            let firstRect, dividerRect, secondRect: CGRect
            if axis == .horizontal {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstLength, height: rect.height)
                dividerRect = CGRect(x: rect.minX + firstLength, y: rect.minY, width: dividerThickness, height: rect.height)
                secondRect = CGRect(x: dividerRect.maxX, y: rect.minY, width: secondLength, height: rect.height)
            } else {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstLength)
                dividerRect = CGRect(x: rect.minX, y: rect.minY + firstLength, width: rect.width, height: dividerThickness)
                secondRect = CGRect(x: rect.minX, y: dividerRect.maxY, width: rect.width, height: secondLength)
            }
            a.collectFrames(in: firstRect, dividerThickness: dividerThickness, into: &frames)
            frames.dividers.append(PaneDividerSlot(id: id, axis: axis, rect: dividerRect, span: rect,
                                                   dividerThickness: dividerThickness))
            b.collectFrames(in: secondRect, dividerThickness: dividerThickness, into: &frames)
        }
    }
}

extension PaneDropEdge {
    /// 落在 rect 的这一侧时,新内容将占据的那一半(拖标签的预览框)
    func half(of rect: CGRect) -> CGRect {
        switch self {
        case .left: CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right: CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .bottom: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        }
    }
}

// MARK: - 动画期间冻结终端网格

/// 分屏布局动画期间冻结终端行列:pane 的 frame 每帧在变,但终端视图保持原尺寸
/// (宿主容器裁切/露底),动画结束只做一次真正的 resize —— 一次 SIGWINCH,
/// TUI(claude 等)只重绘一次,而不是一秒几十次地闪
@MainActor
enum PaneResizeGate {
    static let releasedNotification = Notification.Name("PaneResizeGate.released")

    private static var holds = 0
    private static var generation = 0

    static var isHeld: Bool { holds > 0 }

    static func hold() {
        holds += 1
        generation += 1
        let token = generation
        // 兜底:动画完成回调万一没来(视图被拆等),1 秒后强制放行
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard holds > 0, generation == token else { return }
            holds = 0
            NotificationCenter.default.post(name: releasedNotification, object: nil)
        }
    }

    static func release() {
        guard holds > 0 else { return }
        holds -= 1
        if holds == 0 {
            NotificationCenter.default.post(name: releasedNotification, object: nil)
        }
    }
}

/// 拖标签进 pane 时的落点边
enum PaneDropEdge: Equatable {
    case left, right, top, bottom

    /// 点在 rect 里离哪条边最近(按归一化距离,长宽不同的 pane 也公平)
    static func nearest(to point: CGPoint, in rect: CGRect) -> PaneDropEdge {
        guard rect.width > 0, rect.height > 0 else { return .right }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        let distances: [(PaneDropEdge, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        return distances.min { $0.1 < $1.1 }!.0
    }
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
    /// 巡视模式(⇧⌘\):所有 pane 等宽横排、分页滑动;布局树不动,关掉即还原
    var isCarousel = false
    /// 绑定的侧边栏项目路径:点同一个项目切回本标签,项目移除时本标签一起关
    var projectPath: String?
    /// 用户自定义标签名(双击/右键重命名);nil = 跟随聚焦会话自动标题
    var customTitle: String?
    /// 标签名行内编辑中(双击或右键「重命名」触发,不持久化)
    var isRenaming = false

    init(sessionID: UUID) {
        self.root = .leaf(sessionID)
        self.focusedID = sessionID
    }
}
