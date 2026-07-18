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
