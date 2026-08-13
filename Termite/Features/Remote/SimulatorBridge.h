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

/// 全部模拟器(含未启动的):@[@{@"udid",@"name",@"runtime",@"state"}],
/// 手机端据此列出可启动的设备
+ (NSArray<NSDictionary *> *)allDevices;

/// 启动 / 关闭模拟器。走 simctl 而不是私有 API —— 生命周期操作不值得冒崩的风险
+ (void)bootDevice:(NSString *)udid completion:(void (^)(BOOL ok, NSString *_Nullable error))completion;
+ (void)shutdownDevice:(NSString *)udid completion:(void (^)(BOOL ok, NSString *_Nullable error))completion;

/// 屏幕像素尺寸,拿不到返回 CGSizeZero
+ (CGSize)screenSize:(NSString *)udid;

@end

/// 输入注入(坐标是归一化的 0~1)
@interface SimulatorBridge (Input)

/// 逐阶段触摸,给远端实时跟手用:0=按下 1=移动 2=抬起。
/// identifier 同一次手势内保持一致,iOS 靠它把 down/move/up 串成一根手指
+ (BOOL)touch:(NSString *)udid phase:(int)phase
            x:(double)x y:(double)y
   identifier:(uint32_t)identifier
   bottomEdge:(BOOL)bottomEdge;

/// 单指点按
+ (BOOL)tap:(NSString *)udid x:(double)x y:(double)y hold:(double)seconds;

/// 滑动/拖拽。steps 越多越跟手;dwellMs 是终点停留时间
/// (从底边上滑时 iOS 靠停留时长区分「回主屏」和「应用切换器」)
+ (BOOL)swipe:(NSString *)udid
         fromX:(double)x1 y:(double)y1
           toX:(double)x2 y:(double)y2
      duration:(double)seconds
   fromBottomEdge:(BOOL)bottomEdge;

@end

NS_ASSUME_NONNULL_END
