#import "SimulatorBridge.h"

#import <dlfcn.h>
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
        // 缓存的屏还能出画面就直接用
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
        CGSize size = CGSizeZero;
        id screen = [self cachedScreenForDevice:device udid:udid.UUIDString];
        if (screen) {
            id props = [screen screenProperties];
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
