#import "DFHForeground.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

/* =====================================================================
 * DFHForeground.m — 前台 App 白名单校验实现
 *
 * SpringBoard 私有 API 获取前台应用，多种方法按优先级降级尝试：
 *   1. [[UIApplication sharedApplication] frontmostApplication]（iOS 7+ 通用）
 *   2. [SBApplicationController sharedInstance].frontmostApplication
 *   3. FBSSystemService（FrontBoard）兜底
 *
 * 全部通过 objc_msgSend 运行时调用，不依赖私有无头文件，避免 SDK 依赖。
 * ===================================================================== */

static NSMutableSet<NSString *> *gDFHExtraBundles(void) {
    static NSMutableSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSMutableSet setWithObjects:DFH_BUNDLE_CN, DFH_BUNDLE_INT, nil];
    });
    return set;
}

BOOL DFHIsWhitelistEnabled(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"whiteListEnabled"];
    if (v == nil) return YES;              /* 默认开启 */
    return [v boolValue];
}

static NSString *DFH_BundleIDOf(id app) {
    if (!app) return nil;
    /* 尝试 bundleIdentifier 属性 */
    SEL selBID = NSSelectorFromString(@"bundleIdentifier");
    if ([app respondsToSelector:selBID]) {
        NSString *bid = ((id (*)(id, SEL))objc_msgSend)(app, selBID);
        if (bid.length) return bid;
    }
    /* 尝试 bundleID 属性（旧 API，无公开声明，必须走 msgSend） */
    SEL selBIDOld = NSSelectorFromString(@"bundleID");
    if ([app respondsToSelector:selBIDOld]) {
        NSString *bid = ((id (*)(id, SEL))objc_msgSend)(app, selBIDOld);
        if (bid.length) return bid;
    }
    return nil;
}

NSString *DFHCurrentFrontmostBundleID(void) {
    /* 方法 1：UIApplication frontmostApplication */
    UIApplication *app = [UIApplication sharedApplication];
    SEL sel = NSSelectorFromString(@"frontmostApplication");
    if ([app respondsToSelector:sel]) {
        id fm = ((id (*)(id, SEL))objc_msgSend)(app, sel);
        NSString *bid = DFH_BundleIDOf(fm);
        if (bid.length) return bid;
    }

    /* 方法 2：SBApplicationController */
    Class cls = NSClassFromString(@"SBApplicationController");
    if (cls) {
        id ctrl = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"sharedInstance"));
        if (ctrl) {
            SEL f = NSSelectorFromString(@"frontmostApplication");
            if ([ctrl respondsToSelector:f]) {
                id fm = ((id (*)(id, SEL))objc_msgSend)(ctrl, f);
                NSString *bid = DFH_BundleIDOf(fm);
                if (bid.length) return bid;
            }
            SEL f2 = NSSelectorFromString(@"frontmostApplicationDisplayBundleID");
            if ([ctrl respondsToSelector:f2]) {
                id bid = ((id (*)(id, SEL))objc_msgSend)(ctrl, f2);
                if ([bid isKindOfClass:[NSString class]] && [bid length]) return bid;
            }
        }
    }
    return nil;
}

BOOL DFHIsDeltaForceForeground(void) {
    if (!DFHIsWhitelistEnabled()) return YES;   /* 未启用白名单则放行（兼容旧行为） */
    NSString *bid = DFHCurrentFrontmostBundleID();
    if (!bid) return NO;
    return [gDFHExtraBundles() containsObject:bid] ||
           [bid hasPrefix:@"com.tencent"] ||    /* 兜底：腾讯系（可选，见 README） */
           [bid hasPrefix:@"com.garena"];
}

void DFHAddExtraBundleID(NSString *bundleID) {
    if (bundleID.length) [gDFHExtraBundles() addObject:bundleID];
}
