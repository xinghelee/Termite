import Darwin
import Foundation

// termite-ptyhost:Termite 的会话保活守护进程。
// app 按需拉起;app 退出后 shell 继续活在这里,重启后经 socket 重连。
// 自身完全无状态(会话丢了就是丢了),协议版本编在 socket 文件名里。

// 脱离 app 的进程组;GUI app 无控制终端,不会有 SIGHUP,但防手动从终端起
setsid()
signal(SIGHUP, SIG_IGN)
signal(SIGPIPE, SIG_IGN)

let socketURL = PtyHostPaths.socketURL
try? FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)

// stderr 定向到日志文件(排查用,追加写)
let logPath = socketURL.deletingLastPathComponent().appendingPathComponent("ptyhost.log").path
freopen(logPath, "a", stderr)

// 全局持有:server 一释放 DispatchSource 就全静默了
let server: HostServer
do {
    server = try HostServer(socketPath: socketURL.path)
} catch {
    log("启动失败:\(error)")
    exit(1)
}
server.run()
log("termite-ptyhost 启动,协议 v\(ptyHostProtocolVersion),socket=\(socketURL.path)")

dispatchMain()
