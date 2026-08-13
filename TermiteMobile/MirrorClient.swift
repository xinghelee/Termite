import Foundation
import Observation
import UIKit

/// 模拟器镜像客户端:单开一条 WS 连接专收画面。
///
/// 为什么不复用终端那条连接:帧和终端输出都是二进制帧,靠 SIMG 魔数区分固然可行,
/// 但终端里 `echo SIMG` 就能伪造出同样的开头。分开连就没有这种歧义,
/// 顺带让镜像的流量和终端互不干扰(镜像随时可停,终端不受影响)。
@MainActor
@Observable
final class MirrorClient {
    struct Device: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let runtime: String
        let width: Int
        let height: Int

        private enum CodingKeys: String, CodingKey {
            case id, name, runtime, width, height
        }
    }

    private(set) var devices: [Device] = []
    /// Mac 上的 Xcode 私有接口不可用时为 false,整块功能隐藏
    private(set) var available = true
    private(set) var attachedID: String?
    private(set) var frame: UIImage?
    private(set) var frameSize: CGSize = .zero
    private(set) var connected = false
    private(set) var message: String?

    /// 实测帧率,显示在浮窗角标上
    private(set) var fps: Double = 0
    private var frameTimes: [Date] = []

    private var task: URLSessionWebSocketTask?
    private var endpoint: Endpoint?
    private var generation = 0
    private let decodeQueue = DispatchQueue(label: "mirror.decode", qos: .userInitiated)

    func connect(_ endpoint: Endpoint) {
        guard task == nil || self.endpoint != endpoint else { return }
        self.endpoint = endpoint
        shutdown(keepEndpoint: true)
        guard let url = endpoint.wsURL else { return }
        generation += 1
        let gen = generation
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()
        receive(socket, gen: gen)
        connected = true
        requestList()
    }

    func shutdown(keepEndpoint: Bool = false) {
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
        attachedID = nil
        frame = nil
        if !keepEndpoint { endpoint = nil }
    }

    func requestList() {
        send(["type": "simList"])
    }

    /// maxWidth 给的是画面宽度上限:浮窗小的时候没必要传大图,省流量也省解码
    func attach(_ udid: String, maxWidth: Int = 480, fps: Double = 15) {
        attachedID = udid
        frameTimes = []
        send(["type": "simAttach", "udid": udid, "cols": maxWidth,
              "quality": 0.55, "fps": fps])
    }

    func detach() {
        guard attachedID != nil else { return }
        attachedID = nil
        frame = nil
        send(["type": "simDetach"])
    }

    private func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func receive(_ socket: URLSessionWebSocketTask, gen: Int) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receive(socket, gen: gen)
                case .failure:
                    self.connected = false
                    // 镜像断了不自动重连:浮窗是显式打开的,交给用户再点一次
                    self.attachedID = nil
                }
            }
        }
    }

    private func handle(_ incoming: URLSessionWebSocketTask.Message) {
        switch incoming {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { return }
            switch type {
            case "simList":
                available = obj["available"] as? Bool ?? true
                if let raw = obj["devices"],
                   let payload = try? JSONSerialization.data(withJSONObject: raw),
                   let list = try? JSONDecoder().decode([Device].self, from: payload) {
                    devices = list
                }
            case "simState":
                self.message = obj["message"] as? String
                if obj["udid"] == nil { attachedID = nil }
            default:
                break
            }
        case .data(let data):
            decode(data)
        @unknown default:
            break
        }
    }

    /// 帧格式:SIMG(4) + 宽(2,大端) + 高(2) + JPEG
    private func decode(_ data: Data) {
        guard data.count > 8, data.prefix(4) == Data("SIMG".utf8) else { return }
        let width = Int(data[4]) << 8 | Int(data[5])
        let height = Int(data[6]) << 8 | Int(data[7])
        let jpeg = data.subdata(in: 8..<data.count)
        decodeQueue.async { [weak self] in
            guard let image = UIImage(data: jpeg) else { return }
            Task { @MainActor in
                guard let self else { return }
                self.frame = image
                self.frameSize = CGSize(width: width, height: height)
                self.tickFPS()
            }
        }
    }

    private func tickFPS() {
        let now = Date()
        frameTimes.append(now)
        frameTimes.removeAll { now.timeIntervalSince($0) > 2 }
        fps = Double(frameTimes.count) / 2.0
    }
}
