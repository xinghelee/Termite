#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

NS_ASSUME_NONNULL_BEGIN

/// CoreSimulator 私有 API 的胶水层。
///
/// 为什么是 ObjC 而不是 Swift:这些接口的返回值没有可空性契约,端口还是 ROCK 的 XPC 代理,
/// Swift 那边靠 @objc 协议 + unsafeBitCast 去接,元类型转换和 nil 返回都会直接 trap
/// (实测崩在 swift_unknownObjectRetain)。ObjC 里 id 就是 id,发消息给 nil 也只是返回 nil。
@interface SimulatorBridge : NSObject

/// 私有框架是否加载成功(Xcode 缺失或版本不匹配时为 NO,功能整体降级)
@property (class, readonly) BOOL available;

/// 已启动的模拟器:@[@{@"udid", @"name", @"runtime", @"width", @"height"}]
+ (NSArray<NSDictionary *> *)bootedDevices;

/// 开始接收某台模拟器的帧。回调在自己的串行队列上,给的是当前 framebuffer 的 IOSurface。
/// 返回的 token 用于停止;失败返回 nil(设备不在、没通电的屏、私有接口不可用)。
+ (nullable id)startCapture:(NSString *)udid
                    onFrame:(void (^)(IOSurfaceRef surface))onFrame;

+ (void)stopCapture:(id)token;

/// 屏幕像素尺寸,拿不到返回 CGSizeZero
+ (CGSize)screenSize:(NSString *)udid;

@end

NS_ASSUME_NONNULL_END
