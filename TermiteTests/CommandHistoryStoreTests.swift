import XCTest
@testable import Termite

final class CommandHistoryStoreTests: XCTestCase {

    private var store: CommandHistoryStore!
    private var path: String!

    override func setUp() {
        path = NSTemporaryDirectory() + "termite-test-\(UUID().uuidString).sqlite"
        store = CommandHistoryStore(path: path)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    private func flush() {
        // record 是异步入库,用一次同步查询把队列排干
        _ = store.search("")
    }

    func testRecordAndSearch() {
        store.record(command: "git status", cwd: "/tmp/repo", exitCode: 0, duration: 0.2, branch: "main")
        store.record(command: "npm run build", cwd: "/tmp/web", exitCode: 1, duration: 12, branch: nil)
        flush()
        let all = store.search("")
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.command, "npm run build") // 时间倒序

        let git = store.search("git")
        XCTAssertEqual(git.count, 1)
        XCTAssertEqual(git.first?.branch, "main")
        XCTAssertEqual(git.first?.exitCode, 0)

        let byDir = store.search("web")
        XCTAssertEqual(byDir.count, 1)
    }

    func testTodayIncludesFreshEntries() {
        store.record(command: "ls", cwd: "/", exitCode: 0, duration: nil, branch: nil)
        flush()
        XCTAssertEqual(store.today().count, 1)
    }

    func testEmptyCommandNotRecorded() {
        store.record(command: "   ", cwd: "/", exitCode: 0, duration: nil, branch: nil)
        flush()
        XCTAssertEqual(store.search("").count, 0)
    }

    func testStripPrompt() {
        XCTAssertEqual(CommandHistoryStore.stripPrompt("➜ Termite git:(main) ✗ ls -la"), "ls -la")
        XCTAssertEqual(CommandHistoryStore.stripPrompt("zc@host ~ % echo hi"), "echo hi")
        XCTAssertEqual(CommandHistoryStore.stripPrompt("❯ make build"), "make build")
        XCTAssertEqual(CommandHistoryStore.stripPrompt("plaincmd"), "plaincmd")
    }
}

final class PortMonitorTests: XCTestCase {

    func testParseLsofOutput() {
        let sample = """
        COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node    41234   zc   23u  IPv4 0xabcdef      0t0  TCP 127.0.0.1:5173 (LISTEN)
        node    41234   zc   24u  IPv6 0xabcdf0      0t0  TCP [::1]:5173 (LISTEN)
        python3 52345   zc   3u   IPv4 0xabcdf1      0t0  TCP *:8000 (LISTEN)
        """
        let entries = PortMonitor.parse(sample)
        XCTAssertEqual(entries.count, 2) // IPv4/IPv6 去重
        XCTAssertEqual(entries[0].port, 5173)
        XCTAssertEqual(entries[0].command, "node")
        XCTAssertEqual(entries[1].port, 8000)
        XCTAssertEqual(entries[1].address, "*")
    }
}
