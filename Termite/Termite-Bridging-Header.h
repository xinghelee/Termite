// Swift ↔ ObjC 桥接。这里只放私有 API 的胶水层 ——
// CoreSimulator 那套接口没有可空性契约,在 Swift 里接会直接 trap(见 SimulatorBridge.h)
#import "Features/Remote/SimulatorBridge.h"
