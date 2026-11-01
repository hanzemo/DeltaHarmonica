#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <roothide.h>
#import "DFHCore.h"
#import "DFHForeground.h"
#import "DFHMIDIParser.h"
#import "DFHPlayer.h"

/* =====================================================================
 * Tweak.xm — DeltaHarmonica 入口（Logos）
 *
 * 注入目标：SpringBoard（系统级），不对游戏进程做任何注入（防封号）。
 *
 * 面板触发：仅当「前台是三角洲」时，按「音量下键」打开/关闭控制面板。
 *   实现：多层 hook 兜底
 *     1. SpringBoard -_volumeChanged:（最底层 IOHID 音量事件）
 *     2. SBVolumeControl -decreaseVolume / _decreaseVolume
 *     3. _SBVolumeControl -decreaseVolume / _decreaseVolume
 *   任一层命中即拦截（不调 %orig），音量不变，并切换面板。
 *   非三角洲前台：一律 %orig，音量键正常。
 *
 * 其它入口：
 *   - Darwin 通知 com.hanzemo.deltaharmonica.toggle（dfhctl panel）
 *   - 启动 1 秒后自动弹一次（仅用于验证注入，正式可删）
 *
 * Bundle ID（查证结果）：
 *   国服（腾讯天游） com.tencent.tmgp.dfm
 *   国际服（Garena）  com.garena.game.df
 * ===================================================================== */

static NSString * const kDFHBundleCN  = @"com.tencent.tmgp.dfm";  /* 国服 */
static NSString * const kDFHBundleInt = @"com.garena.game.df";    /* 国际服 */

static CFStringRef const kDFHNotifyPlay   = CFSTR("com.hanzemo.deltaharmonica.play");
static CFStringRef const kDFHNotifyStop   = CFSTR("com.hanzemo.deltaharmonica.stop");
static CFStringRef const kDFHNotifyReplay = CFSTR("com.hanzemo.deltaharmonica.replay");
static CFStringRef const kDFHNotifyToggle = CFSTR("com.hanzemo.deltaharmonica.toggle");

/* ---------------- Debug 宏 ---------------- */
#define DFHLOG(fmt, ...) do { \
    NSString *s = [NSString stringWithFormat:@"[DFH] " fmt "\n", ##__VA_ARGS__]; \
    NSString *p = @"/var/mobile/Documents/dfh.log"; \
    FILE *f = fopen(p.UTF8String, "a"); \
    if (f) { fputs(s.UTF8String, f); fclose(f); } \
} while(0)

/* ---------------- 乐谱目录 ---------------- */
static NSString *DFHMidiDirectory(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *base = jbroot(@"/var/mobile/Documents/DeltaHarmonica");
        dir = base;
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:nil];
    });
    return dir;
}

/* ---------------- 演奏控制 ---------------- */
static void DFHPlayMidiFile(NSString *fileName) {
    NSString *path = [DFHMidiDirectory() stringByAppendingPathComponent:fileName];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        DFHLOG(@"未找到 MIDI：%@", path);
        return;
    }
    if (!DFHIsDeltaForceForeground()) {
        DFHLOG(@"拒绝播放：前台 App 非三角洲（%@）", DFHCurrentFrontmostBundleID() ?: @"未知");
        return;
    }
    NSError *err = nil;
    DFHMIDIResult *res = [DFHMIDIParser parseFileAtPath:path error:&err];
    if (!res) { DFHLOG(@"解析失败：%@", err.localizedDescription); return; }
    [[NSUserDefaults standardUserDefaults] setObject:fileName forKey:@"lastMidi"];
    DFHLOG(@"播放 %@：%lu 音符 BPM=%.1f", fileName, (unsigned long)res.notes.count, res.bpm);
    [[DFHPlayer shared] playResult:res];
}

static void DFHReplayLast(void) {
    NSString *last = [[NSUserDefaults standardUserDefaults] objectForKey:@"lastMidi"];
    if (last.length) DFHPlayMidiFile(last);
}

/* ---------------- 设置界面（悬浮窗） ---------------- */

static UIWindow *gDFHWindow = nil;

@interface DFHPanelViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSString *> *midiFiles;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation DFHPanelViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.frame = self.view.bounds;
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];   /* 深色半透明，不红块 */
    self.view.layer.cornerRadius = 16;
    self.view.clipsToBounds = YES;

    CGFloat w = self.view.bounds.size.width;
    if (w <= 1) {
        w = [UIScreen mainScreen].bounds.size.width * 0.9;
        self.view.frame = CGRectMake(0, 0, w, [UIScreen mainScreen].bounds.size.height * 0.7);
    }
    CGFloat topY = 8;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, topY, w-80, 32)];
    title.text = @"三角洲口琴 · 控制台";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:16];
    [self.view addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(w-60, topY, 48, 32);
    [close setTitle:@"收起" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    topY += 40;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, topY, w-24, 20)];
    self.statusLabel.text = @"就绪";
    self.statusLabel.textColor = [UIColor systemGreenColor];
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    [self.view addSubview:self.statusLabel];
    topY += 26;

    UILabel *listHead = [[UILabel alloc] initWithFrame:CGRectMake(12, topY, w-24, 20)];
    listHead.text = @"乐谱（.mid）";
    listHead.textColor = [UIColor lightGrayColor];
    listHead.font = [UIFont systemFontOfSize:12];
    [self.view addSubview:listHead];
    topY += 22;

    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, topY, w, 0) style:UITableViewStylePlain];
    self.table.delegate = self;
    self.table.dataSource = self;
    self.table.backgroundColor = [UIColor clearColor];
    self.table.separatorColor = [UIColor colorWithWhite:0.3 alpha:1];
    [self.view addSubview:self.table];

    topY += self.table.frame.size.height;

    NSArray *buttons = @[@"▶ 播放", @"⏹ 停止", @"🔁 重播", @"📂 导入", @"🎯 标定", @"🛡 白名单"];
    CGFloat bw = (w - 12*2 - 8*(buttons.count-1)) / (CGFloat)buttons.count;
    CGFloat bx = 12;
    for (NSUInteger i = 0; i < buttons.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(bx, topY, bw, 44);
        [b setTitle:buttons[i] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1];
        b.layer.cornerRadius = 8;
        b.tag = i;
        [b addTarget:self action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];
        bx += bw + 8;
    }
    DFHLOG(@"PanelVC viewDidLoad: bounds=%@", NSStringFromCGRect(self.view.bounds));
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    self.table.frame = CGRectMake(0, 96, w, h - 96 - 60);
}

- (void)hidePanel {
    gDFHWindow.hidden = YES;
    DFHLOG(@"面板隐藏（收起按钮）");
}

- (void)buttonTapped:(UIButton *)b {
    switch (b.tag) {
        case 0: {
            NSIndexPath *ip = self.table.indexPathForSelectedRow;
            if (ip && ip.row < self.midiFiles.count) DFHPlayMidiFile(self.midiFiles[ip.row]);
            break;
        }
        case 1: [[DFHPlayer shared] stop]; self.statusLabel.text = @"已停止"; break;
        case 2: DFHReplayLast(); break;
        case 3: [self importMidi]; break;
        case 4: [self startCalibration]; break;
        case 5: {
            BOOL cur = DFHIsWhitelistEnabled();
            [[NSUserDefaults standardUserDefaults] setBool:!cur forKey:@"whiteListEnabled"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self refreshList];
            break;
        }
    }
}

- (void)importMidi {
    [self refreshList];
    self.statusLabel.text = @"已刷新，请用 Filza 放入 .mid";
}

- (void)startCalibration {
    self.statusLabel.text = @"标定：请依次点 13 键（见 README）";
    DFHLOG(@"开始标定流程（UI 简化版）");
}

- (void)refreshList {
    NSError *err = nil;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:DFHMidiDirectory() error:&err];
    NSMutableArray *mids = [NSMutableArray array];
    for (NSString *f in files) {
        if ([[f lowercaseString] hasSuffix:@".mid"] || [[f lowercaseString] hasSuffix:@".midi"]) {
            [mids addObject:f];
        }
    }
    self.midiFiles = [mids sortedArrayUsingSelector:@selector(compare:)];
    [self.table reloadData];

    NSString *fbid = DFHCurrentFrontmostBundleID();
    BOOL dfOn = DFHIsDeltaForceForeground();
    self.statusLabel.text = [NSString stringWithFormat:@"%lu 首 · 前台 %@ %@",
                             (unsigned long)self.midiFiles.count,
                             fbid ?: @"未知",
                             dfOn ? @"✓可演奏" : @"✗非三角洲"];
    self.statusLabel.textColor = dfOn ? [UIColor systemGreenColor] : [UIColor systemRedColor];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshList];
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    (void)tv; (void)s;
    return self.midiFiles.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"midiCell";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        c.backgroundColor = [UIColor clearColor];
        c.textLabel.textColor = [UIColor whiteColor];
        c.detailTextLabel.textColor = [UIColor lightGrayColor];
    }
    c.textLabel.text = self.midiFiles[ip.row];
    c.detailTextLabel.text = @"点击后按 ▶ 播放";
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    DFHPlayMidiFile(self.midiFiles[ip.row]);
}

@end

/* ---------------- 悬浮窗管理 ---------------- */

static void DFHShowPanel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gDFHWindow) {
            CGRect r = [UIScreen mainScreen].bounds;
            CGFloat w = MIN(r.size.width * 0.9, 420);
            CGFloat h = MIN(r.size.height * 0.7, 520);
            CGRect wr = CGRectMake((r.size.width - w)/2, (r.size.height - h)/2, w, h);
            gDFHWindow = [[UIWindow alloc] initWithFrame:wr];
            gDFHWindow.rootViewController = [DFHPanelViewController new];
            gDFHWindow.backgroundColor = [UIColor clearColor];
            DFHLOG(@"创建窗口: %@", NSStringFromCGRect(wr));
        }
        gDFHWindow.windowLevel = UIWindowLevelAlert + 1000;
        gDFHWindow.hidden = NO;
        DFHLOG(@"ShowPanel: window=%@ hidden=%d level=%.0f",
               gDFHWindow, gDFHWindow.hidden, gDFHWindow.windowLevel);
    });
}

static void DFHHidePanel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gDFHWindow) gDFHWindow.hidden = YES;
        DFHLOG(@"HidePanel");
    });
}

static BOOL DFHPanelVisible(void) {
    return gDFHWindow && !gDFHWindow.hidden;
}

/* 统一处理一次“音量下”事件：只在三角洲前台拦截，并切换面板。
 * 返回 YES 表示已拦截（不要继续调 %orig）。 */
static BOOL DFHHandleVolumeDownFrom(const char *where) {
    NSString *bid = DFHCurrentFrontmostBundleID();
    BOOL df = DFHIsDeltaForceForeground();
    DFHLOG(@"音量下事件命中[%s] 前台=%@ 三角洲=%d 面板可见=%d",
           where, bid ?: @"nil", df, DFHPanelVisible());

    if (!df) return NO;   /* 非三角洲，放行音量 */

    if (DFHPanelVisible()) DFHHidePanel(); else DFHShowPanel();
    return YES;           /* 吞掉音量变化 */
}

/* ---------------- 音量下键多层 hook ---------------- */

/* 第 1 层：SpringBoard -_volumeChanged:（最底层，参数是 IOHIDEventRef）
 * 注意：_volumeChanged: 同时会在音量上/下时触发，需要通过事件方向判断。
 * 这里保守做法：只在 decrease 类方法里拦截；_volumeChanged: 仅作日志观察，
 * 避免误拦音量上。若 decrease 层都没命中，再启用本层的“强制拦截”。 */
%group SpringBoardVolumeHook
%hook SpringBoard

- (BOOL)_volumeChanged:(struct __IOHIDEvent *)event {
    BOOL df = DFHIsDeltaForceForeground();
    DFHLOG(@"SpringBoard _volumeChanged: 前台=%@ 三角洲=%d 面板可见=%d",
           DFHCurrentFrontmostBundleID() ?: @"nil", df, DFHPanelVisible());
    /* 默认放行，避免误拦音量上；decrease 层命中时会自行 return，不走到这里 */
    return %orig;
}

%end
%end

/* 第 2/3 层：SBVolumeControl / _SBVolumeControl 的 decrease 方法。
 * 这两个类名在不同 iOS 版本存在差异，两个都 hook，用 %group 保护，
 * 类不存在时 Logos 会跳过该组。 */
%group VolumeControlHook

%hook SBVolumeControl
- (void)decreaseVolume {
    if (DFHHandleVolumeDownFrom("SBVolumeControl decreaseVolume")) return;
    %orig;
}
- (void)_decreaseVolume {
    if (DFHHandleVolumeDownFrom("SBVolumeControl _decreaseVolume")) return;
    %orig;
}
%end

%hook _SBVolumeControl
- (void)decreaseVolume {
    if (DFHHandleVolumeDownFrom("_SBVolumeControl decreaseVolume")) return;
    %orig;
}
- (void)_decreaseVolume {
    if (DFHHandleVolumeDownFrom("_SBVolumeControl _decreaseVolume")) return;
    %orig;
}
%end

%end /* VolumeControlHook */

/* ---------------- 通知回调 ---------------- */

static void DFHNotifyCallback(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)object;
    if (CFStringCompare(name, kDFHNotifyPlay, 0) == kCFCompareEqualTo) {
        NSString *fn = nil;
        if (userInfo) {
            CFStringRef f = (CFStringRef)CFDictionaryGetValue(userInfo, CFSTR("filename"));
            if (f) fn = (__bridge NSString *)f;
        }
        if (fn.length) DFHPlayMidiFile(fn);
    } else if (CFStringCompare(name, kDFHNotifyStop, 0) == kCFCompareEqualTo) {
        [[DFHPlayer shared] stop];
    } else if (CFStringCompare(name, kDFHNotifyReplay, 0) == kCFCompareEqualTo) {
        DFHReplayLast();
    } else if (CFStringCompare(name, kDFHNotifyToggle, 0) == kCFCompareEqualTo) {
        DFHLOG(@"收到 toggle 通知 → ShowPanel");
        DFHShowPanel();
    }
}

/* ---------------- Debug：启动时打印类/方法是否存在 ---------------- */

static void DFHDebugDumpVolumeClasses(void) {
    const char *names[] = { "SBVolumeControl", "_SBVolumeControl", "VolumeControl", "SpringBoard" };
    for (size_t i = 0; i < sizeof(names)/sizeof(names[0]); i++) {
        Class c = objc_getClass(names[i]);
        DFHLOG(@"class %s = %@", names[i], c ? NSStringFromClass(c) : @"(null)");
        if (!c) continue;

        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        for (unsigned int j = 0; j < count; j++) {
            const char *sel = sel_getName(method_getName(methods[j]));
            if (strstr(sel, "volume") || strstr(sel, "Volume") ||
                strstr(sel, "decrease") || strstr(sel, "Decrease") ||
                strstr(sel, "down") || strstr(sel, "Down")) {
                DFHLOG(@"  %s -%s", names[i], sel);
            }
        }
        free(methods);
    }
}

/* ---------------- 构造器：注入 SpringBoard ---------------- */

__attribute__((constructor))
static void DFHInit(void) {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    DFHLOG(@"构造器进入：bundle=%@", bundleId);
    if (![bundleId isEqualToString:@"com.apple.springboard"]) {
        DFHLOG(@"非 SpringBoard，跳过初始化");
        return;
    }

    DFHDebugDumpVolumeClasses();

    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(nc, NULL, DFHNotifyCallback, kDFHNotifyPlay, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(nc, NULL, DFHNotifyCallback, kDFHNotifyStop, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(nc, NULL, DFHNotifyCallback, kDFHNotifyReplay, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(nc, NULL, DFHNotifyCallback, kDFHNotifyToggle, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    %init(SpringBoardVolumeHook);
    %init(VolumeControlHook);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DFHLOG(@"启动 1s 自动弹面板（验证用）");
        DFHShowPanel();
    });

    DFHLOG(@"DeltaHarmonica 已注入 SpringBoard（音量下键唤起面板，仅三角洲生效）");
}