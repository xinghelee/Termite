import Foundation

/// asciinema v2(.cast)读写:首行 JSON 头,之后每行一个 [time, "o", data] 事件
enum CastFile {

    struct Header: Codable {
        var version: Int
        var width: Int
        var height: Int
        var timestamp: Int?
    }

    struct Event: Equatable {
        let time: Double
        let data: String
    }

    static func headerLine(width: Int, height: Int, timestamp: Date) -> String {
        let header = Header(version: 2, width: width, height: height, timestamp: Int(timestamp.timeIntervalSince1970))
        guard let data = try? JSONEncoder().encode(header),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"version":2,"width":80,"height":24}"#
        }
        return text
    }

    /// 单个输出事件行;JSON 转义交给 JSONSerialization
    static func eventLine(time: Double, data: String) -> String? {
        let payload: [Any] = [(time * 1000).rounded() / 1000, "o", data]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]),
              let text = String(data: encoded, encoding: .utf8) else { return nil }
        return text
    }

    static func parse(_ text: String) -> (header: Header, events: [Event])? {
        var lines = text.components(separatedBy: "\n")[...]
        guard let headerLine = lines.first,
              let headerData = headerLine.data(using: .utf8),
              let header = try? JSONDecoder().decode(Header.self, from: headerData) else { return nil }
        lines = lines.dropFirst()
        var events: [Event] = []
        for line in lines where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let array = raw as? [Any], array.count >= 3,
                  let time = (array[0] as? NSNumber)?.doubleValue,
                  let kind = array[1] as? String, kind == "o",
                  let payload = array[2] as? String else { continue }
            events.append(Event(time: time, data: payload))
        }
        return (header, events)
    }
}
