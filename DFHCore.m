#import "DFHCore.h"
#import "DFHForeground.h"
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <unistd.h>
#import <math.h>

/* =====================================================================
 * DFHCore.m — 核心实现（SpringBoard 注入版）
 *
 * 触摸注入原理（方案 B：只注入 SpringBoard，不碰游戏）：
 *   《三角洲行动》为 Unity 引擎游戏，触摸走 IOHIDEvent。
 *   SpringBoard 是系统级进程，可通过 BackBoardServices 的
 *   BKSHIDEventRouter 把合成触摸投递到"当前前台 App"（即游戏），
 *   全程不对游戏二进制做注入，显著降低被反作弊检测的风险。
 *
 * 参考：AutoTouch / ForceTouchGesture / SimulateTouch 等 SpringBoard 注入插件
 * 均采用 BKSHIDEventRouter 或 IOHIDEventSystemClient 的全局派发路径。
 * ===================================================================== */

/* ---------- BackBoardServices 私有符号（运行时弱链接） ---------- */
/* BKSHIDEventRouter：系统级 HID 事件路由，可向指定 pid / 前台 App 投递触摸 */
@interface BKSHIDEventRouter : NSObject
+ (instancetype)sharedInstance;
- (void)routeEvent:(id)event toProcessWithPid:(int)pid; /* 变体之一 */
@end

/* 简化：多数实现直接使用 IOHIDEventSystemClient 全局派发；本节保留
 * BKSHIDEventRouter 的声明作为高级通道，实际注入走 IOHID 通道。 */

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(
    CFAllocatorRef allocator, uint64_t timeStamp,
    uint32_t transducerType, uint32_t index, uint32_t identity,
    uint32_t inRange, uint32_t quality,
    uint32_t x, uint32_t y, uint32_t z, uint32_t pressure,
    uint32_t twist, uint32_t isTouch, uint32_t options);

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);

/* 事件阶段常量 */
#define kDFH_TouchPhase_Began 0x01
#define kDFH_TouchPhase_Range 0x04

/* ===================================================================== */
/* 标定坐标存取                                                        */
/* ===================================================================== */

static NSString * const kDFHCoordPrefix = @"coord.";

BOOL DFHStoreCoord(NSInteger keyIdx, CGPoint p) {
    NSString *k = [NSString stringWithFormat:@"%@%ld", kDFHCoordPrefix, (long)keyIdx];
    [[NSUserDefaults standardUserDefaults] setObject:NSStringFromCGPoint(p) forKey:k];
    [[NSUserDefaults standardUserDefaults] synchronize];
    return YES;
}

CGPoint DFHLoadCoord(NSInteger keyIdx, BOOL *valid) {
    NSString *k = [NSString stringWithFormat:@"%@%ld", kDFHCoordPrefix, (long)keyIdx];
    NSString *s = [[NSUserDefaults standardUserDefaults] objectForKey:k];
    if ([s isKindOfClass:[NSString class]]) {
        if (valid) *valid = YES;
        return CGPointFromString(s);
    }
    if (valid) *valid = NO;
    return CGPointZero;
}

/* ===================================================================== */
/* 触摸注入                                                            */
/* ===================================================================== */

static IOHIDEventSystemClientRef DFHSharedClient(void) {
    static IOHIDEventSystemClientRef client = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    });
    return client;
}

static void DFHSendTouch(uint32_t finger, int phase, uint32_t x, uint32_t y, uint64_t ts) {
    IOHIDEventSystemClientRef client = DFHSharedClient();
    if (!client) { NSLog(@"[DFH] IOHID client 不可用"); return; }

    IOHIDEventRef ev = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts,
        0x00,                          /* transducerType */
        0,                             /* index */          // ← 补上
        finger,                        /* identity */
        1,                             /* inRange（绝对坐标） */
        phase,                         /* quality / range / touch */
        x, y, 0, 0,                    /* x,y,z,pressure */
        0,                             /* twist */          // ← 补上
        1,                             /* isTouch */
        0);                            /* options */

    if (ev) {
        IOHIDEventSystemClientDispatchEvent(client, ev);
        CFRelease(ev);
    }
}

/* 白名单护栏：仅当前台 App 是三角洲时才允许派发触摸 */
static BOOL DFHShouldInject(void) {
    BOOL ok = DFHIsDeltaForceForeground();
    if (!ok) {
        /* 前台非三角洲，拒绝注入，防误触/防封号 */
        NSLog(@"[DFH] 前台非三角洲（%@），已拦截触摸注入", DFHCurrentFrontmostBundleID() ?: @"未知");
    }
    return ok;
}

void DFHTapAtPoint(CGPoint point, double holdMs) {
    if (!DFHShouldInject()) return;

    CGFloat scale = [UIScreen mainScreen].scale;
    uint32_t x = (uint32_t)lround(point.x * scale);
    uint32_t y = (uint32_t)lround(point.y * scale);

    uint64_t ts = mach_absolute_time();
    DFHSendTouch(1, kDFH_TouchPhase_Began, x, y, ts);

    if (holdMs > 0.0) {
        usleep((useconds_t)(holdMs * 1000.0));
    }

    DFHSendTouch(1, kDFH_TouchPhase_Range, x, y, mach_absolute_time());
}

void DFHTapKey(NSInteger keyIdx, double holdMs) {
    BOOL valid = NO;
    CGPoint p = DFHLoadCoord(keyIdx, &valid);
    if (!valid) {
        NSLog(@"[DFH] 键 %ld 未标定，跳过", (long)keyIdx);
        return;
    }
    DFHTapAtPoint(p, holdMs);
}
