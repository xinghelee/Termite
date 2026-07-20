import Darwin
import Foundation

/// 守护进程侧的一个 PTY 会话:持有 master fd 与 shell 子进程,
/// 输出进环形缓冲,客户端在线时同步转发。
/// 所有方法都在 HostServer 的串行队列上调用。
final class HostSession {
    let id: UUID
    let pid: pid_t
    let cwd: String
    let startedAt = Date()
    private(set) var alive = true
    private(set) var exitCode: Int32?
    private(set) var ring = OutputRing()

    private let masterFD: Int32
    private var readSource: DispatchSourceRead?
    private let writer: FDWriter
    /// 输出到达时回调(已在队列上);exited 由 HostServer 的 SIGCHLD 统一分发
    var onOutput: ((UUID, UInt64, Data) -> Void)?

    init(request: PtyCreateRequest, queue: DispatchQueue) throws {
        id = request.id
        cwd = request.cwd

        // fork 前在父进程把 C 数组备好:fork 后的子进程分支只能碰 async-signal-safe 调用
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(request.argv0), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = request.env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let shellC = strdup(request.shellPath)
        let cwdC = strdup(request.cwd)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            free(shellC)
            free(cwdC)
        }

        var size = winsize()
        size.ws_col = UInt16(request.cols)
        size.ws_row = UInt16(request.rows)
        var master: Int32 = 0
        let child = forkpty(&master, nil, nil, &size)
        if child < 0 {
            throw PtyStreamError.badFrame("forkpty 失败 errno=\(errno)")
        }
        if child == 0 {
            // 子进程:切工作目录后 exec shell;cwd 失效(外置盘未挂载)退回 HOME 由 app 侧保证
            _ = chdir(cwdC)
            execve(shellC, argv, envp)
            _exit(127)
        }

        pid = child
        masterFD = master
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        writer = FDWriter(fd: master, queue: queue)

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        readSource = source
        source.setEventHandler { [weak self] in self?.drainOutput() }
        source.resume()
    }

    private func drainOutput() {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(masterFD, &buf, buf.count)
            if n > 0 {
                let start = ring.tailOffset
                let data = Data(buf[0..<n])
                ring.append(data)
                onOutput?(id, start, data)
                continue
            }
            // n == 0(EOF)或 EIO:子进程已退出,等 SIGCHLD 收尸;EAGAIN:本轮读空
            return
        }
    }

    func send(_ bytes: Data) {
        guard alive else { return }
        writer.write(bytes)
    }

    func resize(cols: Int, rows: Int) {
        guard alive else { return }
        var size = winsize()
        size.ws_col = UInt16(cols)
        size.ws_row = UInt16(rows)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    /// SIGCHLD 收尸后标记退出;master fd 保留到 purge,让残留输出先冲进环形缓冲
    func markExited(code: Int32?) {
        alive = false
        exitCode = code
        drainOutput()
    }

    /// 关闭 pane(⌘W)= 挂断整个进程组,与 TerminalSession.shutdown 行为一致
    func hangup() {
        guard alive else { return }
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
    }

    func purge() {
        readSource?.cancel()
        readSource = nil
        writer.close()
        close(masterFD)
    }

    var info: PtySessionInfo {
        PtySessionInfo(id: id, pid: pid, cwd: cwd, startedAt: startedAt,
                       alive: alive, exitCode: exitCode,
                       headOffset: ring.headOffset, tailOffset: ring.tailOffset)
    }
}
