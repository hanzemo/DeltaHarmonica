#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

/* =====================================================================
 * DeltaHarmonicaPrefsRootController (Preferences 偏好设置面板)
 *
 * 注意：偏好 bundle 里的控制器类名需与 plist 中 detail 一致，
 * 这里提供一个极简实现，实际"开始标定"动作通过 Darwin 通知派发给游戏进程。
 * ===================================================================== */

@interface DeltaHarmonicaPrefsListContoller : UIViewController
@end

@implementation DeltaHarmonicaPrefsListContoller

- (void)startCalibration {
    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterPostNotification(nc, CFSTR("com.hanzemo.deltaharmonica.calibrate"), NULL, NULL, true);
}

- (void)openScoresDir {
    /* 通过 URL scheme 打开目录（依赖 Filza 等；简化演示，实际可扩展） */
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"filza:///var/jb/var/mobile/Documents/DeltaHarmonica"] options:@{} completionHandler:nil];
}

@end
