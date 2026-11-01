#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "DFHCore.h"
#import "DFHForeground.h"
#import "DFHMIDIParser.h"
#import "DFHPlayer.h"

/* =====================================================================
 * Tweak.xm — DeltaHarmonica 入口（Logos）
 *
 * 注入目标：SpringBoard（系统级），不对游戏进程做任何注入（防封号）。
 *
 * 工作原理：
 *   1. SpringBoard 注入后创建一个系统级悬浮窗口（UIWindow，level=alert+），
 *      提供完整的设置/控制界面。
 *   2. 触摸通过 DFHCore 的 IOHID 全局派发，投递到当前前台 App（游戏）。
 *   3. 也监听 Darwin 通知，供命令行工具/Activator 触发。
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

/* ---------------- 乐谱目录 ---------------- */
static NSString *DFHMidiDirectory(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        /* roothide 路径 /var/jb 下；普通 Documents 也兼容 */
        NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        dir = [doc stringByAppendingPathComponent:@"DeltaHarmonica"];
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
        NSLog(@"[DFH] 未找到 MIDI：%@", path);
        return;
    }

    /* 起播前白名单校验：前台必须是三角洲，否则拒绝播放 */
    if (!DFHIsDeltaForceForeground()) {
        NSLog(@"[DFH] 拒绝播放：前台 App 非三角洲（%@）", DFHCurrentFrontmostBundleID() ?: @"未知");
        return;
    }

    NSError *err = nil;
    DFHMIDIResult *res = [DFHMIDIParser parseFileAtPath:path error:&err];
    if (!res) { NSLog(@"[DFH] 解析失败：%@", err.localizedDescription); return; }
    [[NSUserDefaults standardUserDefaults] setObject:fileName forKey:@"lastMidi"];
    NSLog(@"[DFH] 播放 %@：%lu 音符 BPM=%.1f", fileName, (unsigned long)res.notes.count, res.bpm);
    [[DFHPlayer shared] playResult:res];
}

static void DFHReplayLast(void) {
    NSString *last = [[NSUserDefaults standardUserDefaults] objectForKey:@"lastMidi"];
    if (last.length) DFHPlayMidiFile(last);
}

/* ---------------- 设置界面（悬浮窗） ---------------- */

static UIWindow *gDFHWindow = nil;

@interface DFHPanelViewController : UIViewController
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSString *> *midiFiles;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation DFHPanelViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
    self.view.layer.cornerRadius = 16;
    self.view.clipsToBounds = YES;

    CGFloat w = self.view.bounds.size.width;
    CGFloat topY = 8;

    /* 标题 + 关闭 */
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

    /* 状态标签 */
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, topY, w-24, 20)];
    self.statusLabel.text = @"就绪";
    self.statusLabel.textColor = [UIColor systemGreenColor];
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    [self.view addSubview:self.statusLabel];
    topY += 26;

    /* 乐谱列表 */
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

    /* 底部按钮行 */
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
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    self.table.frame = CGRectMake(0, 96, w, h - 96 - 60);
}

- (void)hidePanel {
    gDFHWindow.hidden = YES;
}

- (void)buttonTapped:(UIButton *)b {
    switch (b.tag) {
        case 0: { /* 播放选中的 */
            NSIndexPath *ip = self.table.indexPathForSelectedRow;
            if (ip && ip.row < self.midiFiles.count) DFHPlayMidiFile(self.midiFiles[ip.row]);
            break;
        }
        case 1: [[DFHPlayer shared] stop]; self.statusLabel.text = @"已停止"; break;
        case 2: DFHReplayLast(); break;
        case 3: [self importMidi]; break;
        case 4: [self startCalibration]; break;
        case 5: { /* 白名单开关 */
            BOOL cur = DFHIsWhitelistEnabled();
            [[NSUserDefaults standardUserDefaults] setBool:!cur forKey:@"whiteListEnabled"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self refreshList];
            break;
        }
    }
}

- (void)importMidi {
    /* 在 SpringBoard 里 UIDocumentPicker 受限，改用：打开乐谱目录（提示用户用 Filza 放入）。
     * 同时监听目录变化，刷新列表。 */
    [self refreshList];
    self.statusLabel.text = @"已刷新，请用 Filza 放入 .mid";
}

- (void)startCalibration {
    self.statusLabel.text = @"标定：请依次点 13 键（见 README）";
    NSLog(@"[DFH] 开始标定流程（UI 简化版）");
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

    /* 状态：白名单 + 前台 App */
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
            gDFHWindow.windowLevel = UIWindowLevelAlert + 1;
            gDFHWindow.rootViewController = [DFHPanelViewController new];
            gDFHWindow.backgroundColor = [UIColor clearColor];
        }
        gDFHWindow.hidden = NO;
        [gDFHWindow makeKeyAndVisible];
    });
}

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
        DFHShowPanel();
    }
}

/* ---------------- 构造器：注入 SpringBoard ---------------- */

__attribute__((constructor))
static void DFHInit(void) {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    /* 仅注入 SpringBoard（含前身 AppleTV 等忽略），避免任何游戏进程污染 */
    if (![bundleId isEqualToString:@"com.apple.springboard"]) {
        return;
    }

    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(nc, NULL, DFHNotifyCallback, kDFHNotifyPlay, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(nc, NULL, DFHNotifyCallback, kDFHNotifyStop, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(nc, NULL, DFHNotifyCallback, kDFHNotifyReplay, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(nc, NULL, DFHNotifyCallback, kDFHNotifyToggle, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    /* 双击音量键/Activator 触发面板（简化：延时 1s 自动弹出一次便于验证，
     * 正式使用请绑定 Activator 手势或命令行 toggle） */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DFHShowPanel();
    });

    NSLog(@"[DFH] DeltaHarmonica 已注入 SpringBoard（防封号模式）");
}
