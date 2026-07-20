import Foundation

/// termite-ptyhost 守护进程与 app 之间的线上协议。
/// 帧格式:[type: u8][length: u32 BE][payload]。
/// 控制帧 payload 为 JSON;INPUT/OUTPUT 走二进制热路径(见各 case 注释)。
/// 协议不兼容时直接换 socket 文件名(PtyHostPaths.socketURL 带版本号),
/// 旧守护进程随其会话自然消亡,不做跨版本兼容。
enum PtyFrameType: UInt8 {
    // app → 守护进程
    case hello = 0x01      // JSON PtyHello
    case create = 0x02     // JSON PtyCreateRequest
    case attach = 0x03     // JSON PtyAttachRequest
    case list = 0x04       // 空 payload
    case input = 0x10      // [uuid: 16B][bytes]
    case resize = 0x11     // JSON PtyResizeRequest
    case detach = 0x12     // JSON PtySessionRef
    case kill = 0x13       // JSON PtySessionRef(对已死会话 = 清除记录)
    // 守护进程 → app
    case helloAck = 0x81   // JSON PtyHello
    case created = 0x82    // JSON PtyCreated
    case attached = 0x83   // JSON PtyAttached(其后紧跟 backlog 的 output 帧)
    case exited = 0x84     // JSON PtyExited
    case listing = 0x85    // JSON [PtySessionInfo]
    case output = 0x90     // [uuid: 16B][startOffset: u64 BE][bytes]
    case errorReply = 0xFF // JSON PtyError
}

let ptyHostProtocolVersion = 1

struct PtyHello: Codable {
    var version: Int
}

struct PtyCreateRequest: Codable {
    var id: UUID
    var shellPath: String
    /// argv[0],登录 shell 惯例带 "-" 前缀(如 "-zsh")
    var argv0: String
    var env: [String: String]
    var cwd: String
    var cols: Int
    var rows: Int
}

struct PtyCreated: Codable {
    var id: UUID
    var pid: Int32
}

struct PtyAttachRequest: Codable {
    var id: UUID
    /// 客户端已消费到的流偏移;守护进程从这里续传 backlog。
    /// 早于环形缓冲头部时从头部全量补发,gap = true。
    var sinceOffset: UInt64
}

struct PtyAttached: Codable {
    var id: UUID
    /// backlog 实际起点(≥ sinceOffset 表示无缝续传)
    var fromOffset: UInt64
    /// true = sinceOffset 之前有输出已被环形缓冲丢弃,存在缺口
    var gap: Bool
}

struct PtyResizeRequest: Codable {
    var id: UUID
    var cols: Int
    var rows: Int
}

struct PtySessionRef: Codable {
    var id: UUID
}

struct PtyExited: Codable {
    var id: UUID
    var exitCode: Int32?
}

struct PtySessionInfo: Codable {
    var id: UUID
    var pid: Int32
    var cwd: String
    var startedAt: Date
    var alive: Bool
    var exitCode: Int32?
    /// 环形缓冲覆盖的流偏移区间 [headOffset, tailOffset)
    var headOffset: UInt64
    var tailOffset: UInt64
}

struct PtyError: Codable {
    var message: String
}

enum PtyHostPaths {
    /// 版本号编进文件名:协议演进即换新 socket,老守护进程不受打扰
    static var socketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Termite/ptyhost-v\(ptyHostProtocolVersion).sock")
    }
}

// MARK: - 帧编解码

enum PtyFrameCodec {
    /// 单帧上限:INPUT/OUTPUT 由发送方切块,控制帧远小于此
    static let maxPayload = 4 * 1024 * 1024

    static func encode(_ type: PtyFrameType, payload: Data = Data()) -> Data {
        var frame = Data(capacity: 5 + payload.count)
        frame.append(type.rawValue)
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    static func encode<T: Encodable>(_ type: PtyFrameType, json value: T) -> Data {
        encode(type, payload: (try? JSONEncoder().encode(value)) ?? Data())
    }

    /// INPUT 帧:[uuid][bytes]
    static func encodeInput(id: UUID, bytes: some Sequence<UInt8>) -> Data {
        var payload = id.rawBytes
        payload.append(contentsOf: bytes)
        return encode(.input, payload: payload)
    }

    /// OUTPUT 帧:[uuid][startOffset][bytes]
    static func encodeOutput(id: UUID, startOffset: UInt64, bytes: some Sequence<UInt8>) -> Data {
        var payload = id.rawBytes
        var off = startOffset.bigEndian
        withUnsafeBytes(of: &off) { payload.append(contentsOf: $0) }
        payload.append(contentsOf: bytes)
        return encode(.output, payload: payload)
    }

    static func decodeJSON<T: Decodable>(_ payload: Data) -> T? {
        try? JSONDecoder().decode(T.self, from: payload)
    }

    static func decodeInput(_ payload: Data) -> (id: UUID, bytes: Data)? {
        guard payload.count >= 16, let id = UUID(rawBytes: payload.prefix(16)) else { return nil }
        return (id, payload.dropFirst(16))
    }

    static func decodeOutput(_ payload: Data) -> (id: UUID, startOffset: UInt64, bytes: Data)? {
        guard payload.count >= 24, let id = UUID(rawBytes: payload.prefix(16)) else { return nil }
        let off = payload.dropFirst(16).prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (id, off, payload.dropFirst(24))
    }
}

/// 流式帧解析:socket 读到多少喂多少,凑满一帧吐一帧
struct PtyFrameParser {
    private var buffer = Data()

    /// 返回解出的完整帧;遇到未知帧类型或超长帧说明流已错乱,抛弃连接
    mutating func consume(_ data: Data) throws -> [(type: PtyFrameType, payload: Data)] {
        buffer.append(data)
        var frames: [(PtyFrameType, Data)] = []
        while buffer.count >= 5 {
            let raw = buffer[buffer.startIndex]
            guard let type = PtyFrameType(rawValue: raw) else {
                throw PtyStreamError.badFrame("未知帧类型 0x\(String(raw, radix: 16))")
            }
            let len = buffer.dropFirst().prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard len <= PtyFrameCodec.maxPayload else {
                throw PtyStreamError.badFrame("帧超长 \(len)")
            }
            guard buffer.count >= 5 + Int(len) else { break }
            let payload = Data(buffer.dropFirst(5).prefix(Int(len)))
            buffer.removeFirst(5 + Int(len))
            frames.append((type, payload))
        }
        return frames
    }
}

enum PtyStreamError: Error {
    case badFrame(String)
}

extension UUID {
    var rawBytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }

    init?(rawBytes: Data) {
        guard rawBytes.count == 16 else { return nil }
        var tuple: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &tuple) { $0.copyBytes(from: rawBytes) }
        self.init(uuid: tuple)
    }
}
