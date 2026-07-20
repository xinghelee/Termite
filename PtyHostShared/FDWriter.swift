import Darwin
import Foundation

/// 非阻塞 fd 的带缓冲写入:写不动时挂起 DispatchSourceWrite,可写再续。
/// 所有方法须在传入的 queue 上调用。
final class FDWriter {
    private let fd: Int32
    private var pending = Data()
    private var source: DispatchSourceWrite?
    private let queue: DispatchQueue
    private var closed = false

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    func write(_ data: Data) {
        guard !closed else { return }
        pending.append(data)
        flush()
    }

    private func flush() {
        while !pending.isEmpty {
            let n = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                pending.removeFirst(n)
            } else if errno == EAGAIN {
                armSource()
                return
            } else {
                pending.removeAll()
                return
            }
        }
        source?.cancel()
        source = nil
    }

    private func armSource() {
        guard source == nil else { return }
        let s = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in self?.flush() }
        s.resume()
        source = s
    }

    func close() {
        closed = true
        pending.removeAll()
        source?.cancel()
        source = nil
    }
}