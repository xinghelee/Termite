#import "SimulatorBridge.h"

#import <dlfcn.h>
#import <mach/mach_time.h>
#import <malloc/malloc.h>
#import <objc/runtime.h>

// 私有接口只在这里声明,别处一律走 SimulatorBridge
@interface NSObject (TermiteSimPrivate)
+ (id)sharedServiceContextForDeveloperDir:(NSString *)dir error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
- (NSArray *)devices;
- (NSString *)name;
- (NSString *)stateString;
- (NSUUID *)UDID;
- (id)runtime;
- (id)io;
- (NSArray *)ioPorts;
- (id)descriptor;
- (NSString *)portIdentifier;
- (void)connectToDeviceIO:(id)io;
- (id)screenProperties;
- (CGSize)pixelSize;
- (int)powerState;
- (IOSurfaceRef)framebufferSurface;
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid
                          callbackQueue:(dispatch_queue_t)queue
                          frameCallback:(void (^)(void))frame
                surfacesChangedCallback:(void (^)(void))surfaces
              propertiesChangedCallback:(void (^)(void))props;
- (void)unregisterScreenCallbacksWithUUID:(NSUUID *)uuid;
- (void)registerCallbackWithUUID:(NSUUID *)uuid ioSurfacesChangeCallback:(void (^)(void))cb;
- (void)unregisterIOSurfacesChangeCallbackWithUUID:(NSUUID *)uuid;
- (void)setPowerState:(int)state
       completionQueue:(dispatch_queue_t)queue
     completionHandler:(void (^)(NSError *))handler;
- (unsigned int)screenID;
@end

/// 一次采集的句柄:握着屏幕对象和注册用的 UUID,停的时候按同一条路注销
@interface SimCaptureToken : NSObject
@property (nonatomic, strong) id screen;
@property (nonatomic, strong) NSUUID *uuid;
@property (nonatomic, assign) BOOL usedScreenCallbacks;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation SimCaptureToken
@end

@implementation SimulatorBridge

+ (BOOL)available {
    static BOOL loaded = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *core = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/"
                           "Versions/A/CoreSimulator";
        loaded = dlopen(core, RTLD_NOW) != NULL && NSClassFromString(@"SimServiceContext") != nil;
    });
    return loaded;
}

+ (NSString *)developerDir {
    NSString *override = [NSUserDefaults.standardUserDefaults stringForKey:@"remote.mirror.developerDir"];
    if (override.length) return override;
    return @"/Applications/Xcode.app/Contents/Developer";
}

+ (nullable id)deviceSet {
    if (!self.available) return nil;
    Class ctxClass = NSClassFromString(@"SimServiceContext");
    if (![ctxClass respondsToSelector:@selector(sharedServiceContextForDeveloperDir:error:)]) return nil;
    NSError *error = nil;
    id ctx = [ctxClass sharedServiceContextForDeveloperDir:[self developerDir] error:&error];
    if (![ctx respondsToSelector:@selector(defaultDeviceSetWithError:)]) return nil;
    return [ctx defaultDeviceSetWithError:&error];
}

+ (nullable id)bootedDeviceWithUDID:(nullable NSString *)udid {
    id set = [self deviceSet];
    for (id device in [set devices]) {
        if (![[device stateString] isEqualToString:@"Booted"]) continue;
        if (udid && ![[[device UDID] UUIDString] isEqualToString:udid]) continue;
        return device;
    }
    return nil;
}

/// 找「通电且已有画面」的那块屏。一台模拟器同时挂着 LCD / Resizable / Wireless / TVOut,
/// 后三块 powerState=0、surface 恒为 nil,挑错就永远等不到帧。
/// 另外端口是 ROCK 的 XPC 代理,必须先 connectToDeviceIO: 才会活。
/// 屏幕对象按 UDID 缓存:解析一次会 connectToDeviceIO: 并给屏上电,
/// 重复解析等于把已经建好的 XPC 连接再搅一遍,第二次就拿不到 surface 了
+ (NSMutableDictionary<NSString *, id> *)screenCache {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

+ (nullable id)cachedScreenForDevice:(id)device udid:(NSString *)udid {
    @synchronized (self.screenCache) {
        id cached = self.screenCache[udid];
        // 缓存的屏还能出画面就直接用 —— 重连一次就多一次搞崩 backboardd 的机会
        if (cached && [cached framebufferSurface]) return cached;
        id screen = [self activeScreenOfDevice:device];
        if (screen) {
            self.screenCache[udid] = screen;
        } else {
            [self.screenCache removeObjectForKey:udid];
        }
        return screen;
    }
}

+ (nullable id)activeScreenOfDevice:(id)device {
    id io = [device io];
    if (!io) return nil;
    Protocol *renderable = objc_getProtocol("SimDisplayIOSurfaceRenderable");
    if (!renderable) return nil;
    for (id port in [io ioPorts]) {
        if (![port respondsToSelector:@selector(descriptor)]) continue;
        id desc = [port descriptor];
        if (!desc || ![desc conformsToProtocol:renderable]) continue;
        if ([port respondsToSelector:@selector(connectToDeviceIO:)]) {
            [port connectToDeviceIO:io];
        }
        if (![desc respondsToSelector:@selector(screenProperties)]) continue;
        id props = [desc screenProperties];
        if (!props) continue;
        // 主屏是 screenID==1 的那块(LCD);其余 Resizable/Wireless/TVOut 不要
        if ([props respondsToSelector:@selector(screenID)] && [props screenID] != 1) continue;

        // simctl boot 这种无头启动下主屏是断电的,得自己上电 —— 这是 headless 能成的关键。
        // 上电是异步的,等它一下再看有没有画面
        if ([props powerState] != 1 &&
            [desc respondsToSelector:@selector(setPowerState:completionQueue:completionHandler:)]) {
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            [desc setPowerState:1
                completionQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
              completionHandler:^(NSError *error) { dispatch_semaphore_signal(done); }];
            dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        }
        // 上电后首帧要等一小会儿才出来。注意只取一次:desc 是 XPC 代理,
        // 每次调用都是一次跨进程往返,两次结果可能不一致
        IOSurfaceRef surface = NULL;
        for (int i = 0; i < 30; i++) {
            surface = [desc framebufferSurface];
            if (surface) break;
            usleep(50 * 1000);
        }
        if (!surface) continue;
        return desc;
    }
    return nil;
}

+ (NSArray<NSDictionary *> *)bootedDevices {
    NSMutableArray *result = [NSMutableArray array];
    id set = [self deviceSet];
    for (id device in [set devices]) {
        if (![[device stateString] isEqualToString:@"Booted"]) continue;
        NSUUID *udid = [device UDID];
        if (!udid) continue;
        // 列设备绝不碰帧缓冲:connectToDeviceIO: + 上电是有代价的操作,
        // 对每台设备反复做会把 backboardd 的 SimFramebuffer 连接搞崩
        // (崩在 __SFBConnectionConnect,表现为模拟器一闪黑屏就没了)。
        // 尺寸只从已缓存的屏读,没缓存就报 0 —— 真实尺寸随首帧头一起到客户端
        CGSize size = CGSizeZero;
        id cachedScreen = nil;
        @synchronized (self.screenCache) { cachedScreen = self.screenCache[udid.UUIDString]; }
        if (cachedScreen) {
            id props = [cachedScreen screenProperties];
            if (props) size = [props pixelSize];
        }
        id runtime = [device respondsToSelector:@selector(runtime)] ? [device runtime] : nil;
        [result addObject:@{
            @"udid": udid.UUIDString,
            @"name": [device name] ?: udid.UUIDString,
            @"runtime": (runtime && [runtime respondsToSelector:@selector(name)] ? [runtime name] : @"") ?: @"",
            @"width": @((NSInteger)size.width),
            @"height": @((NSInteger)size.height),
        }];
    }
    return result;
}

+ (CGSize)screenSize:(NSString *)udid {
    id device = [self bootedDeviceWithUDID:udid];
    id screen = device ? [self cachedScreenForDevice:device udid:udid] : nil;
    id props = screen ? [screen screenProperties] : nil;
    return props ? [props pixelSize] : CGSizeZero;
}

+ (nullable id)startCapture:(NSString *)udid onFrame:(void (^)(IOSurfaceRef))onFrame {
    id device = [self bootedDeviceWithUDID:udid];
    id screen = device ? [self cachedScreenForDevice:device udid:udid] : nil;
    if (!screen) return nil;

    SimCaptureToken *token = [SimCaptureToken new];
    token.screen = screen;
    token.uuid = [NSUUID UUID];
    token.queue = dispatch_queue_create("com.termite.sim.capture", DISPATCH_QUEUE_SERIAL);

    // 强引用捕获:screen 是 ROCK 的 XPC 代理(NSProxy 派生),弱引用未必被支持,
    // 用 __weak 的话块里第一时间就拿到 nil,回调看起来「注册成功但永远不来」。
    // 生命周期由 token 持有、stopCapture 注销,不构成循环引用
    void (^deliver)(void) = ^{
        IOSurfaceRef surface = [screen framebufferSurface];
        if (surface) onFrame(surface);
    };

    SEL screenCallbacks = NSSelectorFromString(@"registerScreenCallbacksWithUUID:callbackQueue:"
                                               "frameCallback:surfacesChangedCallback:"
                                               "propertiesChangedCallback:");
    if ([screen respondsToSelector:screenCallbacks]) {
        [screen registerScreenCallbacksWithUUID:token.uuid
                                  callbackQueue:token.queue
                                  frameCallback:deliver
                        surfacesChangedCallback:^{}
                      propertiesChangedCallback:^{}];
        token.usedScreenCallbacks = YES;
    } else if ([screen respondsToSelector:@selector(registerCallbackWithUUID:ioSurfacesChangeCallback:)]) {
        [screen registerCallbackWithUUID:token.uuid ioSurfacesChangeCallback:deliver];
    } else {
        return nil;
    }
    // 立刻送一帧当前画面:模拟器静止时根本不推帧,不补这一下,
    // 打开浮窗看到的就是永远的「等待画面」
    dispatch_async(token.queue, deliver);
    return token;
}

+ (void)stopCapture:(id)token {
    if (![token isKindOfClass:[SimCaptureToken class]]) return;
    SimCaptureToken *t = token;
    if (t.usedScreenCallbacks) {
        if ([t.screen respondsToSelector:@selector(unregisterScreenCallbacksWithUUID:)]) {
            [t.screen unregisterScreenCallbacksWithUUID:t.uuid];
        }
    } else if ([t.screen respondsToSelector:@selector(unregisterIOSurfacesChangeCallbackWithUUID:)]) {
        [t.screen unregisterIOSurfacesChangeCallbackWithUUID:t.uuid];
    }
    t.screen = nil;
}

@end

// MARK: - 输入注入
//
// 私有 API 的调用序列参考了 baguette(github.com/tddworks/baguette,Apache-2.0)
// 逆向出来的配方,以下实现为本项目自行编写。三处关键认知都来自那份研究:
//
// 1. 别自己拼 mach 消息 —— SimDeviceLegacyHIDClient 会填 mach 头。它是 Swift 类,
//    ObjC 运行时里的名字被 mangle 成 _TtC12SimulatorKit24SimDeviceLegacyHIDClient
// 2. 发任何事件前要先建 pointer / mouse 服务(预热),否则 guest 收到就崩
// 3. iOS 26 上点击不能走 IndigoHIDMessageForMouseNSEvent(会被误判成 Home 手势或
//    静默丢弃),要自己造 IOHIDEvent 数字化仪父+子事件,经 Trackpad wrapper 包装后
//    再补两处 wrapper 没初始化的字节槽(target 与 edge)

typedef void *(*IndigoServiceFn)(void);
typedef CFTypeRef (*IOHIDCreateDigitizerFn)(CFAllocatorRef, uint64_t, uint32_t,
                                            uint32_t, uint32_t, uint32_t, uint32_t,
                                            double, double, double, double, double,
                                            bool, bool, uint32_t);
typedef CFTypeRef (*IOHIDCreateFingerFn)(CFAllocatorRef, uint64_t,
                                         uint32_t, uint32_t, uint32_t,
                                         double, double, double, double, double,
                                         bool, bool, uint32_t);
typedef void (*IOHIDAppendFn)(CFTypeRef, CFTypeRef, uint32_t);
typedef void *(*IndigoTrackpadWrapFn)(const void *);
typedef id (*HIDClientInitFn)(id, SEL, id, NSError **);
typedef void (*HIDSendFn)(id, SEL, void *, BOOL, id, id);

/// 触摸路由标签,iOS 靠它把事件送进数字化仪子系统
static const uint32_t kTouchTarget = 0x32;

/// IOHID* 在 dyld 共享缓存里(RTLD_DEFAULT 够),Indigo* 要显式 dlopen SimulatorKit
static void *TermiteSimSymbol(const char *name, BOOL inKit) {
    static void *kit;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kit = dlopen("/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/"
                     "SimulatorKit.framework/Versions/A/SimulatorKit", RTLD_NOW);
    });
    return dlsym(inKit ? kit : RTLD_DEFAULT, name);
}

static void TermiteSimSend(void *message, id client) {
    SEL sel = NSSelectorFromString(@"sendWithMessage:freeWhenDone:completionQueue:completion:");
    IMP imp = class_getMethodImplementation(object_getClass(client), sel);
    if (imp) ((HIDSendFn)imp)(client, sel, message, YES, nil, nil);
}

/// 造一次数字化仪事件(父 + 手指子事件),包装成 Indigo 消息并补齐字节槽。
/// phase: 0=按下 1=移动 2=抬起;坐标已归一化
static BOOL TermiteSimSendTouch(id client, double x, double y, int phase,
                                uint32_t identifier, BOOL bottomEdge) {
    IOHIDCreateDigitizerFn createParent =
        (IOHIDCreateDigitizerFn)TermiteSimSymbol("IOHIDEventCreateDigitizerEvent", NO);
    IOHIDCreateFingerFn createFinger =
        (IOHIDCreateFingerFn)TermiteSimSymbol("IOHIDEventCreateDigitizerFingerEvent", NO);
    IOHIDAppendFn append = (IOHIDAppendFn)TermiteSimSymbol("IOHIDEventAppendEvent", NO);
    IndigoTrackpadWrapFn wrap = (IndigoTrackpadWrapFn)
        TermiteSimSymbol("IndigoHIDMessageForTrackpadEventFromHIDEventRef", YES);
    if (!createParent || !createFinger || !append || !wrap) return NO;

    // 按下/移动 = Range|Touch|Position;抬起 = Touch|Position(让 iOS 看到状态变化)
    uint32_t mask = (phase == 2) ? 0x06 : 0x07;
    bool range = (phase != 2), touch = (phase != 2);
    uint64_t now = mach_absolute_time();
    const uint32_t transducerFinger = 2;

    CFTypeRef parent = createParent(NULL, now, transducerFinger, 0, identifier, mask, 0,
                                    x, y, 0.0, 0.0, 0.0, range, touch, 0);
    if (!parent) return NO;
    // 真实触摸永远是父+子成对到达;缺了子事件,wrapper 产出的是 iOS 会忽略的残包
    CFTypeRef finger = createFinger(NULL, now, 0, identifier, mask,
                                    x, y, 0.0, 0.0, 0.0, range, touch, 0);
    if (finger) { append(parent, finger, 0); CFRelease(finger); }

    void *message = wrap(parent);
    CFRelease(parent);
    if (!message) return NO;

    // 补 wrapper 留空的两处:target 路由标签与边缘位掩码,两条记录都要写
    uint32_t target = kTouchTarget;
    size_t size = malloc_size(message);
    memcpy((uint8_t *)message + 0x6c, &target, sizeof(target));
    if (size >= 0x110) memcpy((uint8_t *)message + 0x10c, &target, sizeof(target));
    uint8_t edgeBit = bottomEdge ? 0x01 : 0x00;
    uint8_t edgePresent = bottomEdge ? 0x04 : 0x00;
    *((uint8_t *)message + 0x3a) = edgePresent;
    *((uint8_t *)message + 0x3b) = edgeBit;
    if (size >= 0xdc) {
        *((uint8_t *)message + 0xda) = edgePresent;
        *((uint8_t *)message + 0xdb) = edgeBit;
    }
    TermiteSimSend(message, client);
    return YES;
}

@implementation SimulatorBridge (Input)

/// 每台设备一个 HID 客户端,建好即预热;缓存复用
+ (id)hidClientForUDID:(NSString *)udid {
    static NSMutableDictionary *clients;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ clients = [NSMutableDictionary dictionary]; });
    @synchronized (clients) {
        id existing = clients[udid];
        if (existing) return existing;

        id device = [self bootedDeviceWithUDID:udid];
        if (!device) return nil;
        // 先摸一个符号,顺带把 SimulatorKit 载进来 —— 不然下面按名字找类必然是 nil
        (void)TermiteSimSymbol("IndigoHIDMessageToCreatePointerService", YES);
        // Swift 类,ObjC 运行时里的名字是 mangle 过的
        Class cls = NSClassFromString(@"_TtC12SimulatorKit24SimDeviceLegacyHIDClient");
        if (!cls) { NSLog(@"[sim] 找不到 SimDeviceLegacyHIDClient"); return nil; }
        SEL initSel = NSSelectorFromString(@"initWithDevice:error:");
        IMP imp = class_getMethodImplementation(cls, initSel);
        if (!imp) return nil;
        NSError *error = nil;
        id client = ((HIDClientInitFn)imp)([cls alloc], initSel, device, &error);
        if (!client) return nil;

        // 预热:先建 pointer / mouse 服务,不然第一条事件就会让 guest 崩
        const char *services[] = {"IndigoHIDMessageToCreatePointerService",
                                  "IndigoHIDMessageToCreateMouseService"};
        for (int i = 0; i < 2; i++) {
            IndigoServiceFn fn = (IndigoServiceFn)TermiteSimSymbol(services[i], YES);
            if (!fn) continue;
            void *msg = fn();
            if (msg) { TermiteSimSend(msg, client); usleep(20 * 1000); }
        }
        clients[udid] = client;
        return client;
    }
}

+ (uint32_t)nextTouchIdentifier {
    static uint32_t counter = 1;
    @synchronized (self) { return ++counter; }
}

+ (BOOL)touch:(NSString *)udid phase:(int)phase x:(double)x y:(double)y
   identifier:(uint32_t)identifier bottomEdge:(BOOL)bottomEdge {
    id client = [self hidClientForUDID:udid];
    if (!client) return NO;
    return TermiteSimSendTouch(client, x, y, phase, identifier, bottomEdge);
}

+ (BOOL)tap:(NSString *)udid x:(double)x y:(double)y hold:(double)seconds {
    id client = [self hidClientForUDID:udid];
    if (!client) return NO;
    uint32_t identifier = [self nextTouchIdentifier];
    if (!TermiteSimSendTouch(client, x, y, 0, identifier, NO)) return NO;
    usleep((useconds_t)(MAX(seconds, 0.02) * 1000000));
    return TermiteSimSendTouch(client, x, y, 2, identifier, NO);
}

+ (BOOL)swipe:(NSString *)udid fromX:(double)x1 y:(double)y1 toX:(double)x2 y:(double)y2
     duration:(double)seconds fromBottomEdge:(BOOL)bottomEdge {
    id client = [self hidClientForUDID:udid];
    if (!client) return NO;
    uint32_t identifier = [self nextTouchIdentifier];
    if (!TermiteSimSendTouch(client, x1, y1, 0, identifier, bottomEdge)) return NO;
    const int steps = 12;
    useconds_t stepUs = (useconds_t)(MAX(seconds, 0.1) * 1000000 / steps);
    for (int i = 1; i <= steps; i++) {
        usleep(stepUs);
        double t = (double)i / steps;
        TermiteSimSendTouch(client, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t,
                            1, identifier, bottomEdge);
    }
    usleep(stepUs);
    return TermiteSimSendTouch(client, x2, y2, 2, identifier, bottomEdge);
}

@end
