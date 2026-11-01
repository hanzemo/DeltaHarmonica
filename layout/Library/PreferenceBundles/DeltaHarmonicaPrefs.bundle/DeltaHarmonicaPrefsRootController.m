#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <roothide.h>

/* =====================================================================
 * DeltaHarmonicaPrefsRootController (Preferences 偏好设置面板)
 * roothide：access jailbreak files via jbroot()
 * ===================================================================== */

@interface DeltaHarmonicaPrefsListContoller : UIViewController
@end

@implementation DeltaHarmonicaPrefsListContoller

- (void)startCalibration {
    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterPostNotification(nc, CFSTR("com.hanzemo.deltaharmonica.calibrate"), NULL, NULL, true);
}

- (void)openScoresDir {
    /* roothide：用 jbroot 定位目录，通过 Filza 打开 */
    NSString *dir = jbroot(@"/var/mobile/Documents/DeltaHarmonica");
    NSString *url = [NSString stringWithFormat:@"filza://%@", dir];
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url] options:@{} completionHandler:nil];
}

@end
