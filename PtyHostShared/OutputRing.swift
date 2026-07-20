import Foundation

/// 会话输出的环形缓冲:带单调递增的流偏移,支持"从某偏移续传"。
/// 客户端断开期间输出攒在这里;重连时按已消费偏移补发,超出容量的部分
/// 由 app 侧的 scrollback 快照兜底。
struct OutputRing {
    /// 覆盖区间 [headOffset, tailOffset)
    private(set) var headOffset: UInt64 = 0
    private(set) var tailOffset: UInt64 = 0
    private var storage = Data()
    let capacity: Int

    init(capacity: Int = 2 * 1024 * 1024) {
        self.capacity = capacity
    }

    mutating func append(_ bytes: Data) {
        storage.append(bytes)
        tailOffset += UInt64(bytes.count)
        // 超容 1/4 才修剪,摊薄 removeFirst 的搬移成本
        if storage.count > capacity + capacity / 4 {
            let drop = storage.count - capacity
            storage.removeFirst(drop)
            headOffset += UInt64(drop)
        }
    }

    /// 从 offset 起读到尾部。offset 早于 head 时从 head 全量返回,gap 标记缺口。
    func read(from offset: UInt64) -> (data: Data, fromOffset: UInt64, gap: Bool) {
        let clamped = min(max(offset, headOffset), tailOffset)
        let skip = Int(clamped - headOffset)
        return (Data(storage.dropFirst(skip)), clamped, offset < headOffset)
    }
}
