import XCTest
@testable import Termite

/// 版本号比较:必须逐段数值比,字符串比较会把 1.10 判旧于 1.9
@MainActor
final class UpdateCheckerTests: XCTestCase {
    func testNumericSegmentCompare() {
        XCTAssertTrue(UpdateChecker.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "1.28"))
        XCTAssertTrue(UpdateChecker.isNewer("1.9.1", than: "1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9", than: "1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9", than: "1.10"))
        XCTAssertFalse(UpdateChecker.isNewer("1.8", than: "1.9"))
    }

    func testUnevenSegmentCounts() {
        XCTAssertFalse(UpdateChecker.isNewer("1.9.0", than: "1.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.9", than: "1.8.9"))
    }
}
