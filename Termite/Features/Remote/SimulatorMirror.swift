import CoreImage
import Foundation
import IOSurface

/// 模拟器镜像:直接读模拟器自己的帧缓冲(IOSurface),不走屏幕录制。
///
/// 因此不需要屏幕录制授权、Simulator.app 不用开、不抢焦点,帧率跟模拟器刷新率一致。
/// 私有 API 的胶水在 SimulatorBridge(ObjC),这里只负责挑设备、编码、限流。
@MainActor
@Observable
final class SimulatorMirror {
    static let shared = SimulatorMirror()

    struct Device: Identifiable, Codable, Equatable {
        var id: String        // UDID
        var name: String
        var runtime: String
        var width: Int
        var height: Int
        /// "Booted" / "Shutdown" —— 手机端据此决定是「启动」还是「查看」
        var state: String
    }

    /// 私有框架加载失败(Xcode 缺失或版本对不上)时为 false,客户端整块隐藏
    var available: Bool { SimulatorBridge.available }
    private(set) var streaming: String?

    /// 编码在采集回调线程上做;CIContext 线程安全,拎出主 actor
    private nonisolated let context = CIContext(options: [.useSoftwareRenderer: false])
    private var token: AnyObject?
    /// 限流用:上一帧发出的时刻。只在采集队列上访问
    private nonisolated(unsafe) var lastSent = Date.distantPast

    /// 私有 API 的调用一律在这条队列上:解析屏幕要等 XPC 往返、给屏上电还要等回调,
    /// 放主线程会把它堵死(表现成「CLI 里好好的,app 里永远拿不到 surface」)
    private nonisolated let bridgeQueue = DispatchQueue(label: "com.termite.sim.bridge")

    private init() {}

    /// 全部设备(含未启动的):模拟器 tab 要能列出来并一键启动
    nonisolated func allDevices(completion: @escaping ([Device]) -> Void) {
        bridgeQueue.async {
            let devices = SimulatorBridge.allDevices().compactMap { info -> Device? in
                guard let udid = info["udid"] as? String else { return nil }
                return Device(id: udid,
                              name: info["name"] as? String ?? udid,
                              runtime: info["runtime"] as? String ?? "",
                              width: 0, height: 0,
                              state: info["state"] as? String ?? "Unknown")
            }
            completion(devices)
        }
    }

    nonisolated func boot(udid: String, completion: @escaping (Bool, String?) -> Void) {
        SimulatorBridge.bootDevice(udid, completion: completion)
    }

    nonisolated func shutdown(udid: String, completion: @escaping (Bool, String?) -> Void) {
        SimulatorBridge.shutdownDevice(udid, completion: completion)
    }

    nonisolated func bootedDevices(completion: @escaping ([Device]) -> Void) {
        bridgeQueue.async {
            let devices = SimulatorBridge.bootedDevices().compactMap { info -> Device? in
                guard let udid = info["udid"] as? String else { return nil }
                return Device(id: udid,
                              name: info["name"] as? String ?? udid,
                              runtime: info["runtime"] as? String ?? "",
                              width: info["width"] as? Int ?? 0,
                              height: info["height"] as? Int ?? 0,
                              state: info["state"] as? String ?? "Booted")
            }
            completion(devices)
        }
    }

    /// 开始镜像。onFrame 在采集队列回调,给的是编好的 JPEG(带缩放后的宽高)。
    /// maxFPS 限流是必要的:模拟器满速 60fps,手机走蜂窝吃不消
    nonisolated func start(udid: String, maxWidth: Int, quality: Double, maxFPS: Double,
                           onFrame: @escaping (Data, Int, Int) -> Void,
                           completion: @escaping (Bool) -> Void) {
        stop()
        bridgeQueue.async { [self] in
            let minInterval = maxFPS > 0 ? 1.0 / maxFPS : 0
            lastSent = .distantPast
            let started = SimulatorBridge.startCapture(udid) { surface in
                let now = Date()
                guard now.timeIntervalSince(self.lastSent) >= minInterval else { return }
                self.lastSent = now
                guard let (data, width, height) = self.encode(surface: surface,
                                                              maxWidth: maxWidth,
                                                              quality: quality) else { return }
                onFrame(data, width, height)
            }
            if let started {
                self.setToken(started as AnyObject, udid: udid)
            }
            completion(started != nil)
        }
    }

    /// 远端手指动作:phase 0=按下 1=移动 2=抬起。放 bridgeQueue 上,
    /// 和采集共用一条串行队列,天然避免和帧回调抢私有 API
    nonisolated func touch(udid: String, phase: Int, x: Double, y: Double,
                           identifier: UInt32, bottomEdge: Bool) {
        bridgeQueue.async {
            SimulatorBridge.touch(udid, phase: Int32(phase), x: x, y: y,
                                  identifier: identifier, bottomEdge: bottomEdge)
        }
    }

    nonisolated func stop() {
        bridgeQueue.async { [self] in
            guard let token = takeToken() else { return }
            SimulatorBridge.stopCapture(token)
        }
    }

    private nonisolated func setToken(_ value: AnyObject, udid: String) {
        Task { @MainActor in
            self.token = value
            self.streaming = udid
        }
    }

    /// 取出并清空句柄。停止发生在 bridgeQueue 上,状态却归主 actor,用信号量把这一跳同步掉
    private nonisolated func takeToken() -> AnyObject? {
        var result: AnyObject?
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            result = self.token
            self.token = nil
            self.streaming = nil
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
        return result
    }

    /// IOSurface → 等比缩到 maxWidth → JPEG。IOSurface 是 GPU 内存,CIImage 直接包住不拷贝
    private nonisolated func encode(surface: IOSurfaceRef, maxWidth: Int,
                                    quality: Double) -> (Data, Int, Int)? {
        var image = CIImage(ioSurface: surface)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        var width = Int(extent.width), height = Int(extent.height)
        if maxWidth > 0, width > maxWidth {
            let scale = CGFloat(maxWidth) / extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            width = Int(extent.width * scale)
            height = Int(extent.height * scale)
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return context.jpegRepresentation(
            of: image, colorSpace: space,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:
                        max(0.1, min(quality, 1.0))]
        ).map { ($0, width, height) }
    }
}
