#import "DFHCore.h"
#import "DFHForeground.h"
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <unistd.h>
#import <math.h>
#import <dlfcn.h>

/* =====================================================================
 * DFHCore.m — 核心实现（SpringBoard 注入版）
 *
 * 触摸注入原理（方案 B：只注入 SpringBoard，不碰游戏）：
 *   《三角洲行动》为 Unity 引擎游戏，触摸走 IOHIDEvent。
 *   SpringBoard 是系统级进程，可通过 IOHIDEventSystemClient 的全局派发
 *   把合成触摸投递到"当前前台 App"（即游戏），全程不对游戏二进制做注入。
 *
 * 符号兼容（iOS 14/15/16）：
 *   IOHIDEventCreateDigitizerEvent 在 iOS 14+ 为 15 参（x/y/z/pressure/twist
 *   为 IOHIDFloat），旧 14 参声明会导致调用栈错位、事件静默失败。
 *   这里用 dlopen + dlsym 运行时查找，避免编译期签名不匹配。
 *   优先用 IOHIDEventCreateDigitizerFingerEvent（13 参，更稳）。
 * ===================================================================== */

/* ---------------- Debug 宏（写文件） ---------------- */
#define DFHLOG(fmt, ...) do { \
    NSString *s = [NSString stringWithFormat:@"[DFH] " fmt "\n", ##__VA_ARGS__]; \
    NSString *p = @"/var/mobile/Documents/dfh.log"; \
    FILE *f = fopen(p.UTF8String, "a"); \
    if (f) { fputs(s.UTF8String, f); fclose(f); } \
} while(0)

/* ---------- IOKit 私有符号类型 ---------- */
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);
extern void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t senderID);

/* 事件阶段常量 */
#define kDFH_TouchPhase_Began 0x01
#define kDFH_TouchPhase_Range 0x04

/* ---------- 运行时符号查找 ---------- */
typedef IOHIDEventRef (*DFHFingerEventFn)(CFAllocatorRef, uint64_t,
    uint32_t, uint32_t, uint32_t,
    double, double, double, double, double,
    Boolean, Boolean, uint32_t);

typedef IOHIDEventRef (*DFHDigitizerEventFn)(CFAllocatorRef, uint64_t,
    uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double,
    Boolean, Boolean, uint32_t);

static void *DFHIOKitHandle(void) {
    static void *h = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!h) h = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!h) h = dlopen("/usr/lib/libIOKit.dylib", RTLD_NOW);
    });
    return h;
}

static DFHFingerEventFn DFHCreateFingerEvent(void) {
    static DFHFingerEventFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = DFHIOKitHandle();
        if (h) fn = (DFHFingerEventFn)dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
    });
    return fn;
}

static DFHDigitizerEventFn DFHCreateDigitizerEvent(void) {
    static DFHDigitizerEventFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = DFHIOKitHandle();
        if (h) fn = (DFHDigitizerEventFn)dlsym(h, "IOHIDEventCreateDigitizerEvent");
    });
    return fn;
}

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
    if (!client) {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        DFHLOG(@"IOHIDEventSystemClientCreate -> %p", client);
    }
    return client;
}

static void DFHSendTouch(uint32_t finger, int phase, double nx, double ny, uint64_t ts) {
    IOHIDEventSystemClientRef client = DFHSharedClient();
    if (!client) return;

    Boolean isDown = (phase == kDFH_TouchPhase_Began);
    uint32_t mask = isDown ? 0x07 : 0x06;   /* down: Range|Touch|Position; up: Touch|Position */
    Boolean range = isDown ? 1 : 0;
    Boolean touch = isDown ? 1 : 0;

    IOHIDEventRef ev = NULL;

    DFHFingerEventFn fingerFn = DFHCreateFingerEvent();
    if (fingerFn) {
        ev = fingerFn(kCFAllocatorDefault, ts, 0, finger, mask,
                      nx, ny, 0.0,
                      0.0, 0.0,       /* tipPressure, twist 保持 0 */
                      range, touch, 0);
    }

    if (!ev) {
        DFHDigitizerEventFn digiFn = DFHCreateDigitizerEvent();
        if (digiFn) {
            ev = digiFn(kCFAllocatorDefault, ts,
                        0x00, 0, finger,
                        mask, 0,
                        nx, ny, 0.0, 0.0, 0.0,
                        range, touch, 0);
        }
    }

    if (ev) {
        IOHIDEventSetSenderID(ev, 0x8000000817319372ULL);
        IOHIDEventSystemClientDispatchEvent(client, ev);
        DFHLOG(@"SendTouch ok phase=%d nx=%.3f ny=%.3f", phase, nx, ny);
        CFRelease(ev);
    } else {
        DFHLOG(@"SendTouch 失败: 事件创建返回 NULL");
    }
}

/* 白名单护栏：仅当前台 App 是三角洲时才允许派发触摸 */
static BOOL DFHShouldInject(void) {
    BOOL ok = DFHIsDeltaForceForeground();
    if (!ok) {
        DFHLOG(@"前台非三角洲（%@），拦截触摸", DFHCurrentFrontmostBundleID() ?: @"未知");
    }
    return ok;
}

void DFHTapAtPoint(CGPoint point, double holdMs) {
    if (!DFHShouldInject()) return;

    CGRect screen = [UIScreen mainScreen].bounds;
    if (screen.size.width <= 1 || screen.size.height <= 1) return;

    double nx = point.x / screen.size.width;    /* 0.0–1.0 */
    double ny = point.y / screen.size.height;   /* 0.0–1.0 */

    uint64_t ts = mach_absolute_time();
    DFHSendTouch(1, kDFH_TouchPhase_Began, nx, ny, ts);

    if (holdMs > 0.0) {
        usleep((useconds_t)(holdMs * 1000.0));
    }

    DFHSendTouch(1, kDFH_TouchPhase_Range, nx, ny, mach_absolute_time());
}

void DFHTapKey(NSInteger keyIdx, double holdMs) {
    BOOL valid = NO;
    CGPoint p = DFHLoadCoord(keyIdx, &valid);
    if (!valid) {
        DFHLOG(@"键 %ld 未标定，跳过", (long)keyIdx);
        return;
    }
    DFHLOG(@"TapKey %ld at (%.1f, %.1f) hold=%.1f", (long)keyIdx, p.x, p.y, holdMs);
    DFHTapAtPoint(p, holdMs);
}