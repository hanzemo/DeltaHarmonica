#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

/* =====================================================================
 * DFHForeground.h — 前台 App 白名单校验
 *
 * 用途：仅当"当前前台 App 是《三角洲行动》"时才允许派发触摸，
 *      从源头避免误触/误注入到其他 App，真正提升防封号安全性。
 *
 * 实现：注入 SpringBoard，通过 SpringBoard 私有的
 *      SBApplicationController / UIApplication 拿到前台应用 bundle id。
 * ===================================================================== */

/* 三角洲行动 Bundle ID（查证） */
#define DFH_BUNDLE_CN   @"com.tencent.tmgp.dfm"  /* 国服 */
#define DFH_BUNDLE_INT  @"com.garena.game.df"    /* 国际服 */

/* 是否启用白名单（读偏好 whiteListEnabled，默认 YES） */
BOOL DFHIsWhitelistEnabled(void);

/* 当前前台 App 的 bundle id（可能为 nil） */
NSString * _Nullable DFHCurrentFrontmostBundleID(void);

/* 当前前台 App 是否为三角洲（国服/国际服） */
BOOL DFHIsDeltaForceForeground(void);

/* 手动指定额外的白名单（可选扩展，如测试用） */
void DFHAddExtraBundleID(NSString *bundleID);

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
