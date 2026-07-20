import XCTest
@testable import Termite

final class PtyHostProtocolTests: XCTestCase {

    func testFrameRoundTrip() throws {
        let hello = PtyFrameCodec.encode(.hello, json: PtyHello(version: 7))
        var parser = PtyFrameParser()
        let frames = try parser.consume(hello)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].type, .hello)
        let decoded: PtyHello? = PtyFrameCodec.decodeJSON(frames[0].payload)
        XCTAssertEqual(decoded?.version, 7)
    }

    /// socket 读取会把帧切碎:逐字节喂也必须解出同样的帧序列
    func testParserHandlesFragmentation() throws {
        let id = UUID()
        var stream = PtyFrameCodec.encodeInput(id: id, bytes: Array("hello".utf8))
        stream.append(PtyFrameCodec.encodeOutput(id: id, startOffset: 42, bytes: [0xE5, 0x85, 0xAC]))
        var parser = PtyFrameParser()
        var collected: [(type: PtyFrameType, payload: Data)] = []
        for byte in stream {
            collected += try parser.consume(Data([byte]))
        }
        XCTAssertEqual(collected.map(\.type), [.input, .output])
        let input = PtyFrameCodec.decodeInput(collected[0].payload)
        XCTAssertEqual(input?.id, id)
        XCTAssertEqual(input.map { Array($0.bytes) }, Array("hello".utf8))
        let output = PtyFrameCodec.decodeOutput(collected[1].payload)
        XCTAssertEqual(output?.startOffset, 42)
        XCTAssertEqual(output.map { Array($0.bytes) }, [0xE5, 0x85, 0xAC])
    }

    func testParserRejectsUnknownFrameType() {
        var parser = PtyFrameParser()
        XCTAssertThrowsError(try parser.consume(Data([0x7E, 0, 0, 0, 0])))
    }

    func testUUIDRawBytesRoundTrip() {
        let id = UUID()
        XCTAssertEqual(UUID(rawBytes: id.rawBytes), id)
    }

    // MARK: - OutputRing

    func testRingResumeFromOffset() {
        var ring = OutputRing(capacity: 1024)
        ring.append(Data("abcdef".utf8))
        let resumed = ring.read(from: 4)
        XCTAssertEqual(String(decoding: resumed.data, as: UTF8.self), "ef")
        XCTAssertEqual(resumed.fromOffset, 4)
        XCTAssertFalse(resumed.gap)
    }

    /// 超容修剪后,早于 head 的偏移从 head 全量补发并标记缺口
    func testRingTrimsAndReportsGap() {
        var ring = OutputRing(capacity: 8)
        ring.append(Data(repeating: 0x41, count: 100)) // 触发修剪
        XCTAssertGreaterThan(ring.headOffset, 0)
        XCTAssertEqual(ring.tailOffset, 100)
        let resumed = ring.read(from: 0)
        XCTAssertTrue(resumed.gap)
        XCTAssertEqual(resumed.fromOffset, ring.headOffset)
        XCTAssertEqual(resumed.data.count, Int(ring.tailOffset - ring.headOffset))
        // 尾部之后没有新数据
        let empty = ring.read(from: ring.tailOffset)
        XCTAssertTrue(empty.data.isEmpty)
        XCTAssertFalse(empty.gap)
    }
}
