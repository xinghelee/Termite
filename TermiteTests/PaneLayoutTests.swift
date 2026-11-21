import XCTest
@testable import Termite

final class PaneLayoutTests: XCTestCase {

    func testSplitLeafCreatesBranch() {
        let a = UUID(), b = UUID(), branch = UUID()
        let root = PaneNode.leaf(a).splitting(leaf: a, into: b, axis: .horizontal, branchID: branch)
        XCTAssertEqual(root.leafIDs(), [a, b])
        XCTAssertEqual(root.firstLeaf, a)
    }

    func testNestedSplit() {
        let a = UUID(), b = UUID(), c = UUID()
        var root = PaneNode.leaf(a).splitting(leaf: a, into: b, axis: .horizontal, branchID: UUID())
        root = root.splitting(leaf: b, into: c, axis: .vertical, branchID: UUID())
        XCTAssertEqual(root.leafIDs(), [a, b, c])
    }

    func testRemovingCollapsesBranch() {
        let a = UUID(), b = UUID()
        let root = PaneNode.leaf(a).splitting(leaf: a, into: b, axis: .horizontal, branchID: UUID())
        let collapsed = root.removing(leaf: b)
        XCTAssertEqual(collapsed?.leafIDs(), [a])
        XCTAssertNil(PaneNode.leaf(a).removing(leaf: a))
    }

    func testNeighborLeaf() {
        let a = UUID(), b = UUID(), c = UUID()
        var root = PaneNode.leaf(a).splitting(leaf: a, into: b, axis: .horizontal, branchID: UUID())
        root = root.splitting(leaf: b, into: c, axis: .vertical, branchID: UUID())
        XCTAssertEqual(root.neighborLeaf(of: b), c)
        XCTAssertEqual(root.neighborLeaf(of: a), b)
        XCTAssertEqual(root.neighborLeaf(of: c), b)
    }
}

final class PaneRatioTests: XCTestCase {

    func testSplitDefaultsToHalf() {
        let a = UUID(), b = UUID(), branch = UUID()
        let root = PaneNode.leaf(a).splitting(leaf: a, into: b, axis: .horizontal, branchID: branch)
        guard case .branch(_, _, let ratio, _, _) = root else { return XCTFail() }
        XCTAssertEqual(ratio, 0.5)
    }

    func testSettingRatioClamps() {
        let a = UUID(), b = UUID(), branch = UUID()
        var root = PaneNode.leaf(a).splitting(leaf: a, into: b, axis: .horizontal, branchID: branch)
        root = root.settingRatio(branch: branch, ratio: 0.7)
        guard case .branch(_, _, let ratio, _, _) = root else { return XCTFail() }
        XCTAssertEqual(ratio, 0.7)

        root = root.settingRatio(branch: branch, ratio: 0.01)
        guard case .branch(_, _, let clamped, _, _) = root else { return XCTFail() }
        XCTAssertEqual(clamped, PaneNode.ratioRange.lowerBound)
    }

    func testSettingRatioOnlyTouchesTarget() {
        let a = UUID(), b = UUID(), c = UUID()
        let outer = UUID(), inner = UUID()
        var root = PaneNode.leaf(a).splitting(leaf: a, into: b, axis: .horizontal, branchID: outer)
        root = root.splitting(leaf: b, into: c, axis: .vertical, branchID: inner)
        root = root.settingRatio(branch: inner, ratio: 0.3)
        guard case .branch(_, _, let outerRatio, _, let second) = root,
              case .branch(_, _, let innerRatio, _, _) = second else { return XCTFail() }
        XCTAssertEqual(outerRatio, 0.5)
        XCTAssertEqual(innerRatio, 0.3)
    }

    func testRemovingPreservesRatio() {
        let a = UUID(), b = UUID(), c = UUID()
        let outer = UUID(), inner = UUID()
        var root = PaneNode.leaf(a).splitting(leaf: a, into: b, axis: .horizontal, branchID: outer, ratio: 0.6)
        root = root.splitting(leaf: b, into: c, axis: .vertical, branchID: inner)
        let collapsed = root.removing(leaf: c)
        guard case .branch(_, _, let ratio, _, _)? = collapsed else { return XCTFail() }
        XCTAssertEqual(ratio, 0.6)
    }
}

final class PaneDirectionTests: XCTestCase {

    /// 布局:A | (B / C)  —— A 占左半,B 右上,C 右下
    private func makeLayout() -> (PaneNode, UUID, UUID, UUID) {
        let a = UUID(), b = UUID(), c = UUID()
        var root = PaneNode.leaf(a).splitting(leaf: a, into: b, axis: .horizontal, branchID: UUID())
        root = root.splitting(leaf: b, into: c, axis: .vertical, branchID: UUID())
        return (root, a, b, c)
    }

    func testLeafRectsPartitionUnitSquare() {
        let (root, a, b, c) = makeLayout()
        let rects = root.leafRects()
        XCTAssertEqual(rects.count, 3)
        XCTAssertEqual(rects[a]!, CGRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(rects[b]!, CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(rects[c]!, CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }

    func testVerticalNeighbors() {
        let (root, _, b, c) = makeLayout()
        XCTAssertEqual(root.neighborLeaf(of: b, direction: .down), c)
        XCTAssertEqual(root.neighborLeaf(of: c, direction: .up), b)
        XCTAssertNil(root.neighborLeaf(of: b, direction: .up))
    }

    func testHorizontalNeighbors() {
        let (root, a, b, c) = makeLayout()
        XCTAssertEqual(root.neighborLeaf(of: b, direction: .left), a)
        XCTAssertEqual(root.neighborLeaf(of: c, direction: .left), a)
        let fromA = root.neighborLeaf(of: a, direction: .right)
        XCTAssertTrue(fromA == b || fromA == c)
        XCTAssertNil(root.neighborLeaf(of: a, direction: .left))
    }

    func testRatioAffectsRects() {
        let a = UUID(), b = UUID(), branch = UUID()
        var root = PaneNode.leaf(a).splitting(leaf: a, into: b, axis: .horizontal, branchID: branch)
        root = root.settingRatio(branch: branch, ratio: 0.3)
        let rects = root.leafRects()
        XCTAssertEqual(rects[a]!.width, 0.3, accuracy: 0.0001)
        XCTAssertEqual(rects[b]!.width, 0.7, accuracy: 0.0001)
    }
}

final class PaneKeyboardResizeTests: XCTestCase {
    private func ratio(_ node: PaneNode, _ id: UUID) -> Double? {
        switch node {
        case .leaf: return nil
        case .branch(let bid, _, let r, let a, let b):
            if bid == id { return r }
            return ratio(a, id) ?? ratio(b, id)
        }
    }

    func testArrowMovesDividerInArrowDirection() {
        let a = UUID(), b = UUID(), branch = UUID()
        let root = PaneNode.branch(id: branch, axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        // 不论焦点在哪一侧,→ 都把分隔条往右推
        XCTAssertEqual(ratio(root.resizing(leaf: a, direction: .right)!, branch)!, 0.55, accuracy: 0.0001)
        XCTAssertEqual(ratio(root.resizing(leaf: b, direction: .right)!, branch)!, 0.55, accuracy: 0.0001)
        XCTAssertEqual(ratio(root.resizing(leaf: a, direction: .left)!, branch)!, 0.45, accuracy: 0.0001)
        // 没有上下分隔条
        XCTAssertNil(root.resizing(leaf: a, direction: .up))
    }

    func testNearestMatchingAxisBranchWins() {
        let a = UUID(), b = UUID(), c = UUID(), outer = UUID(), inner = UUID()
        // 左右分屏,右侧再上下分:焦点在 c 上按 ↓ 动内层,按 → 动外层
        let root = PaneNode.branch(id: outer, axis: .horizontal, ratio: 0.5, first: .leaf(a),
                                   second: .branch(id: inner, axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c)))
        XCTAssertEqual(ratio(root.resizing(leaf: c, direction: .down)!, inner)!, 0.55, accuracy: 0.0001)
        XCTAssertEqual(ratio(root.resizing(leaf: c, direction: .left)!, outer)!, 0.45, accuracy: 0.0001)
    }

    func testClampedToRange() {
        let a = UUID(), b = UUID(), branch = UUID()
        let root = PaneNode.branch(id: branch, axis: .vertical, ratio: 0.86, first: .leaf(a), second: .leaf(b))
        XCTAssertEqual(ratio(root.resizing(leaf: a, direction: .down)!, branch)!, PaneNode.ratioRange.upperBound, accuracy: 0.0001)
    }
}

final class TabDropSplitTests: XCTestCase {
    func testNearestEdge() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 200)
        XCTAssertEqual(PaneDropEdge.nearest(to: CGPoint(x: 120, y: 200), in: rect), .left)
        XCTAssertEqual(PaneDropEdge.nearest(to: CGPoint(x: 480, y: 200), in: rect), .right)
        XCTAssertEqual(PaneDropEdge.nearest(to: CGPoint(x: 300, y: 110), in: rect), .top)
        XCTAssertEqual(PaneDropEdge.nearest(to: CGPoint(x: 300, y: 290), in: rect), .bottom)
    }

    func testInsertingSubtreeAtEdge() {
        let host = UUID(), x = UUID(), y = UUID()
        let subtree = PaneNode.branch(id: UUID(), axis: .vertical, ratio: 0.5, first: .leaf(x), second: .leaf(y))
        let left = PaneNode.leaf(host).inserting(subtree, at: host, edge: .left)
        XCTAssertEqual(left.leafIDs(), [x, y, host])
        let bottom = PaneNode.leaf(host).inserting(subtree, at: host, edge: .bottom)
        XCTAssertEqual(bottom.leafIDs(), [host, x, y])
        guard case .branch(_, let axis, _, _, _) = bottom else { return XCTFail() }
        XCTAssertEqual(axis, .vertical)
    }
}
