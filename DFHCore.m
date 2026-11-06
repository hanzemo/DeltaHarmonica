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
 * 触摸注入：
 *   在 SpringBoard 内构造 IOHIDEvent，通过 IOHIDEventSystemClient 全局派发
 *   到当前前台 App（游戏）。真实触摸是 Parent（Digitizer）+ Child（Finger）
 *   成对出现的，必须 IOHIDEventAppendEvent 挂 child 到 parent，再派发 parent。
 *
 * 符号兼容（iOS 14/15/16）：
 *   IOHIDEventCreateDigitizerEvent 是 15 参（x/y/z/pressure/twist 为 IOHIDFloat），
 *   用 dlopen + dlsym 运行时查找，避免编译期签名不匹配。
 *   优先 IOHIDEventCreateDigitizerFingerEvent（13 参，更稳）。
 *
 * 多指：
 *   finger 参数区分不同手指（1–9 音符键，10 切换键），按下/抬起用同一 finger。
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
extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, int value);

/* 事件阶段常量 */
#define kDFH_TouchPhase_Began 0x01
#define kDFH_TouchPhase_Range 0x04

/* IOHID 字段常量 */
#define kDFH_FieldDigitizerIsDisplayIntegrated 0x0000000B

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
    if (!client) { DFHLOG(@"SendTouch: client=NULL"); return; }

    Boolean isDown = (phase == kDFH_TouchPhase_Began);
    uint32_t mask = isDown ? 0x07 : 0x06;
    Boolean range = isDown ? 1 : 0;
    Boolean touch = isDown ? 1 : 0;

    /* 1. 创建 child（Finger），identity 用 finger 区分多指 */
    IOHIDEventRef child = NULL;
    DFHFingerEventFn fingerFn = DFHCreateFingerEvent();
    if (fingerFn) {
        child = fingerFn(kCFAllocatorDefault, ts, 0, finger, mask,
                         nx, ny, 0.0, 0.0, 0.0,
                         range, touch, 0);
    }
    if (!child) { DFHLOG(@"SendTouch: child=NULL"); return; }

    /* 2. 创建 parent（Digitizer） */
    DFHDigitizerEventFn digiFn = DFHCreateDigitizerEvent();
    if (!digiFn) { DFHLOG(@"SendTouch: digiFn=NULL"); CFRelease(child); return; }

    IOHIDEventRef parent = digiFn(kCFAllocatorDefault, ts,
                                  0, 0, finger,
                                  mask, 0,
                                  nx, ny, 0.0, 0.0, 0.0,
                                  range, touch, 0);
    if (!parent) { DFHLOG(@"SendTouch: parent=NULL"); CFRelease(child); return; }

    /* 3. 标记屏幕集成触摸 + 挂 child */
    IOHIDEventSetIntegerValue(parent, kDFH_FieldDigitizerIsDisplayIntegrated, 1);
    IOHIDEventAppendEvent(parent, child);
    CFRelease(child);

    /* 4. SenderID + 派发 parent */
    IOHIDEventSetSenderID(parent, 0x8000000817319372ULL);
    IOHIDEventSystemClientDispatchEvent(client, parent);
    DFHLOG(@"SendTouch ok phase=%d nx=%.3f ny=%.3f finger=%u", phase, nx, ny, finger);
    CFRelease(parent);
}

/* 白名单护栏：仅当前台 App 是三角洲时才允许派发触摸 */
static BOOL DFHShouldInject(void) {
    BOOL ok = DFHIsDeltaForceForeground();
    if (!ok) {
        DFHLOG(@"前台非三角洲（%@），拦截触摸", DFHCurrentFrontmostBundleID() ?: @"未知");
    }
    return ok;
}

void DFHTapAtPoint(CGPoint point, double holdMs, uint32_t finger) {
    if (!DFHShouldInject()) return;

    CGRect screen = [UIScreen mainScreen].bounds;
    if (screen.size.width <= 1 || screen.size.height <= 1) return;

    double nx = point.x / screen.size.width;
    double ny = point.y / screen.size.height;
    if (nx < 0.0) nx = 0.0;
    if (nx > 1.0) nx = 1.0;
    if (ny < 0.0) ny = 0.0;
    if (ny > 1.0) ny = 1.0;

    uint64_t ts = mach_absolute_time();
    DFHSendTouch(finger, kDFH_TouchPhase_Began, nx, ny, ts);

    if (holdMs > 0.0) {
        double nxCopy = nx, nyCopy = ny;
        uint32_t f = finger;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(holdMs * NSEC_PER_MSEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            DFHSendTouch(f, kDFH_TouchPhase_Range, nxCopy, nyCopy, mach_absolute_time());
        });
    } else {
        DFHSendTouch(finger, kDFH_TouchPhase_Range, nx, ny, mach_absolute_time());
    }
}

void DFHTapKey(NSInteger keyIdx, double holdMs, uint32_t finger) {
    BOOL valid = NO;
    CGPoint p = DFHLoadCoord(keyIdx, &valid);
    if (!valid) {
        DFHLOG(@"键 %ld 未标定，跳过", (long)keyIdx);
        return;
    }
    DFHLOG(@"TapKey %ld at (%.1f, %.1f) hold=%.1f finger=%u",
           (long)keyIdx, p.x, p.y, holdMs, finger);
    DFHTapAtPoint(p, holdMs, finger);
}