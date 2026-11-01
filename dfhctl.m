#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

/* =====================================================================
 * dfhctl.m — 命令行触发工具
 *
 * 编译后为 /usr/bin/dfhctl（rootless 下 /var/jb/usr/bin/dfhctl）。
 * 通过 Darwin 通知向 SpringBoard 内的 DeltaHarmonica 发送控制指令。
 *
 * 用法：
 *   dfhctl play song.mid      # 播放指定 MIDI
 *   dfhctl stop               # 停止
 *   dfhctl replay             # 重播上一首
 *   dfhctl panel              # 弹出设置面板
 *   dfhctl list               # 列出乐谱目录里的 .mid
 * ===================================================================== */

static NSString *DFHMidiDirectory(void) {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [doc stringByAppendingPathComponent:@"DeltaHarmonica"];
}

static void postNotification(CFStringRef name, NSDictionary *userInfo) {
    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterPostNotification(nc, name, NULL, (__bridge CFDictionaryRef)userInfo, true);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "用法: dfhctl {play <file.mid>|stop|replay|panel|list}\n");
            return 1;
        }
        NSString *cmd = [NSString stringWithUTF8String:argv[1]];

        if ([cmd isEqualToString:@"play"] && argc >= 3) {
            NSString *fn = [NSString stringWithUTF8String:argv[2]];
            postNotification(CFSTR("com.hanzemo.deltaharmonica.play"), @{ @"filename": fn });
            printf("[dfhctl] 已发送播放指令：%s\n", argv[2]);
        } else if ([cmd isEqualToString:@"stop"]) {
            postNotification(CFSTR("com.hanzemo.deltaharmonica.stop"), nil);
            printf("[dfhctl] 已发送停止指令\n");
        } else if ([cmd isEqualToString:@"replay"]) {
            postNotification(CFSTR("com.hanzemo.deltaharmonica.replay"), nil);
            printf("[dfhctl] 已发送重播指令\n");
        } else if ([cmd isEqualToString:@"panel"]) {
            postNotification(CFSTR("com.hanzemo.deltaharmonica.toggle"), nil);
            printf("[dfhctl] 已弹出设置面板\n");
        } else if ([cmd isEqualToString:@"list"]) {
            NSError *err = nil;
            NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:DFHMidiDirectory() error:&err];
            for (NSString *f in files) {
                NSString *l = [f lowercaseString];
                if ([l hasSuffix:@".mid"] || [l hasSuffix:@".midi"]) {
                    printf("%s\n", f.UTF8String);
                }
            }
        } else {
            fprintf(stderr, "未知命令: %s\n", argv[1]);
            return 1;
        }
    }
    return 0;
}
