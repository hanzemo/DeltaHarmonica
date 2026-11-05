#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <roothide.h>
#import "DFHCore.h"
#import "DFHForeground.h"
#import "DFHMIDIParser.h"
#import "DFHPlayer.h"
#import <math.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

/* =====================================================================
 * Tweak.xm — DeltaHarmonica 入口（Logos）
 *
 * 注入目标：SpringBoard（系统级），不对游戏进程做任何注入（防封号）。
 *
 * 面板触发：仅当「前台是三角洲」时，按「音量下键」打开控制面板。
 *   多层 hook 兜底：SpringBoard -_volumeChanged:（仅日志）、
 *   SBVolumeControl / _SBVolumeControl 的 decreaseVolume / _decreaseVolume。
 *   非三角洲前台：一律 %orig，音量键正常。
 *
 * 面板特性：
 *   - 顶部标题栏可拖动移动窗口
 *   - 「⤢」按钮在小/中/大三档尺寸间循环
 *   - 30 秒无操作自动隐藏（不暂停播放）
 *   - 「🎯 标定」进入 12 键标定界面，逐个点屏幕取坐标
 *
 * 其它入口：
 *   - Darwin 通知 com.hanzemo.deltaharmonica.toggle（dfhctl panel）
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

/* ---------------- Debug 宏（写文件，绕过真机 log 命令限制） ---------------- */
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

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:fileName forKey:@"lastMidi"];
    [ud setObject:@(0) forKey:@"lastPlayedUs"];   /* 从头播 */
    [ud synchronize];

    DFHPlayer *player = [DFHPlayer shared];
    player.currentMidiName = fileName;
    DFHLOG(@"播放 %@：%lu 音符 BPM=%.1f", fileName, (unsigned long)res.notes.count, res.bpm);
    [player playResult:res fromUs:0];
}

static void DFHReplayLast(void) {
    NSString *last = [[NSUserDefaults standardUserDefaults] objectForKey:@"lastMidi"];
    if (last.length) DFHPlayMidiFile(last);
}

/* ---------------- 悬浮窗 ---------------- */

@interface DFHPanelWindow : UIWindow
@end
@implementation DFHPanelWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end

/* 12 个键的名字（与 DFHCore.h 的宏顺序一致） */
static NSArray<NSString *> *DFHKeyNames(void) {
    static NSArray *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[@"do", @"re", @"mi", @"fa", @"sol", @"la", @"si",
                  @"高音 do", @"低音区", @"中音区", @"高音区", @"半音"];
    });
    return names;
}

@class DFHPanelViewController;

static UIWindow *gDFHWindow = nil;

/* ---------------- 标定界面 ---------------- */

@interface DFHCalibrationViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, copy) void (^onFinish)(void);
- (instancetype)initWithFinishBlock:(void (^)(void))block;
@end

@implementation DFHCalibrationViewController

- (instancetype)initWithFinishBlock:(void (^)(void))block {
    if (self = [super init]) { self.onFinish = block; }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, self.view.bounds.size.width - 80, 32)];
    title.text = @"口琴键位标定";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:16];
    [self.view addSubview:title];

    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    back.frame = CGRectMake(self.view.bounds.size.width - 60, 8, 48, 32);
    [back setTitle:@"返回" forState:UIControlStateNormal];
    [back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:back];

    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, 48, self.view.bounds.size.width, self.view.bounds.size.height - 48)
                                              style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.table];
}

- (void)goBack {
    if (gDFHWindow) gDFHWindow.hidden = NO;
    if (self.onFinish) self.onFinish();
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    (void)tv; (void)s;
    return DFH_TOTAL_KEYS;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"calCell";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cid];
        c.backgroundColor = [UIColor clearColor];
        c.textLabel.textColor = [UIColor whiteColor];
        c.detailTextLabel.textColor = [UIColor lightGrayColor];
    }
    BOOL valid = NO;
    CGPoint p = DFHLoadCoord(ip.row, &valid);
    c.textLabel.text = DFHKeyNames()[ip.row];
    c.detailTextLabel.text = valid
        ? [NSString stringWithFormat:@"%.0f, %.0f", p.x, p.y]
        : @"未标定";
    c.detailTextLabel.textColor = valid ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    [self startPickForIndex:ip.row];
}

- (void)startPickForIndex:(NSInteger)idx {
    /* 标定时隐藏面板 */
    if (gDFHWindow) gDFHWindow.hidden = YES;

    /* 选游戏所在场景，取横屏 bounds */
    CGRect r = [UIScreen mainScreen].bounds;
    UIWindowScene *targetScene = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if ([scene.session.role containsString:@"SystemAperture"]) continue;
            if ([scene.session.role containsString:@"Application"]) {
                targetScene = (UIWindowScene *)scene;
                break;
            }
        }
    }
    if (targetScene) r = targetScene.coordinateSpace.bounds;

    UIWindow *pickerWin = [[UIWindow alloc] initWithFrame:r];
    if (targetScene) {
        pickerWin.windowScene = targetScene;
    }
    pickerWin.windowLevel = UIWindowLevelAlert + 2000;
    pickerWin.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];

    UIViewController *picker = [UIViewController new];
    picker.view.backgroundColor = [UIColor clearColor];
    pickerWin.rootViewController = picker;
    pickerWin.hidden = NO;

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(0, 80, r.size.width, 44)];
    hint.text = [NSString stringWithFormat:@"请点击「%@」在屏幕上的位置", DFHKeyNames()[idx]];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.textColor = [UIColor whiteColor];
    hint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    hint.font = [UIFont systemFontOfSize:15];
    [picker.view addSubview:hint];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handlePickTap:)];
    tap.numberOfTapsRequired = 1;
    [picker.view addGestureRecognizer:tap];

    objc_setAssociatedObject(tap, "idx", @(idx), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tap, "pickerWin", pickerWin, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

/* ---------------- 主面板 ---------------- */

@interface DFHPanelViewController : UIViewController <UITableViewDelegate, UITableViewDataSource, UIDocumentPickerDelegate>
@property (nonatomic, strong) UIView *dragBar;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *resizeButton;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UILabel *listHeadLabel;
@property (nonatomic, strong) NSArray<UIButton *> *actionButtons;@property (nonatomic, strong) UISlider *progressSlider;
@property (nonatomic, strong) UIButton *rateButton;
@property (nonatomic, assign) BOOL userDraggingSlider;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSString *> *midiFiles;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSTimer *autoHideTimer;
@property (nonatomic, assign) NSInteger sizeLevel; /* 0 小 1 中 2 大 */
@end

@implementation DFHPanelViewController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscapeLeft | UIInterfaceOrientationMaskLandscapeRight;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.sizeLevel = 1;
    self.view.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
    self.view.layer.cornerRadius = 16;
    self.view.clipsToBounds = YES;

    self.titleLabel = [UILabel new];
    self.titleLabel.text = @"三角洲口琴 · 控制台";
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:16];


    self.resizeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.resizeButton setTitle:@"⤢" forState:UIControlStateNormal];
    [self.resizeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.resizeButton addTarget:self action:@selector(cycleSize) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.resizeButton];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setTitle:@"收起" forState:UIControlStateNormal];
    [self.closeButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [self.closeButton addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.closeButton];

		self.dragBar = [UIView new];
    self.dragBar.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.dragBar];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDrag:)];
    [self.dragBar addGestureRecognizer:pan];

    self.statusLabel = [UILabel new];
    self.statusLabel.text = @"就绪";
    self.statusLabel.textColor = [UIColor systemGreenColor];
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    [self.view addSubview:self.statusLabel];
		self.statusLabel.adjustsFontSizeToFitWidth = YES;
    self.statusLabel.minimumScaleFactor = 0.7;

    self.listHeadLabel = [UILabel new];
    self.listHeadLabel.text = @"乐谱（.mid）";
    self.listHeadLabel.textColor = [UIColor lightGrayColor];
    self.listHeadLabel.font = [UIFont systemFontOfSize:12];
    [self.view addSubview:self.listHeadLabel];
		self.listHeadLabel.adjustsFontSizeToFitWidth = YES;
    self.listHeadLabel.minimumScaleFactor = 0.8;

    self.table = [UITableView new];
    self.table.delegate = self;
    self.table.dataSource = self;
    self.table.backgroundColor = [UIColor clearColor];
    self.table.separatorColor = [UIColor colorWithWhite:0.3 alpha:1];
    [self.view addSubview:self.table];

		NSArray *titles = @[@"▶ 播放", @"⏹ 停止", @"🔁 重播", @"📂 导入", @"🎯 标定"];
    NSMutableArray *btns = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1];
        b.layer.cornerRadius = 8;
        b.tag = i;
        b.titleLabel.adjustsFontSizeToFitWidth = YES;
        b.titleLabel.minimumScaleFactor = 0.6;
        [b addTarget:self action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];
        [btns addObject:b];
    }
    self.actionButtons = btns;

    self.progressSlider = [UISlider new];
    self.progressSlider.minimumValue = 0;
    self.progressSlider.maximumValue = 1;
    self.progressSlider.value = 0;
    [self.progressSlider addTarget:self action:@selector(sliderTouchDown) forControlEvents:UIControlEventTouchDown];
    [self.progressSlider addTarget:self action:@selector(sliderTouchUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.view addSubview:self.progressSlider];

    self.rateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.rateButton setTitle:@"1.0x" forState:UIControlStateNormal];
    [self.rateButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.rateButton.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1];
    self.rateButton.layer.cornerRadius = 8;
    [self.rateButton addTarget:self action:@selector(cycleRate) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.rateButton];

    __weak typeof(self) weakSelf = self;
    [DFHPlayer shared].onProgress = ^(uint64_t playedUs, uint64_t totalUs) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.userDraggingSlider || totalUs == 0) return;
            strongSelf.progressSlider.value = (float)((double)playedUs / (double)totalUs);
        });
    };
}

- (void)layoutPanel {
    CGRect winBounds = gDFHWindow ? gDFHWindow.bounds : self.view.bounds;
    CGFloat w = winBounds.size.width;
    CGFloat h = winBounds.size.height;
    if (w <= 1 || h <= 1) return;

    /* iPhone X 横屏安全区：左右各 44，底部 21 */
    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        safe = gDFHWindow ? gDFHWindow.safeAreaInsets : self.view.safeAreaInsets;
    }
    CGFloat left = MAX(safe.left, 12);
    CGFloat right = MAX(safe.right, 12);
    CGFloat top = MAX(safe.top, 8);
    CGFloat usableW = w - left - right;

    CGFloat topY = top;

    self.dragBar.frame = CGRectMake(0, 0, w - 120, 40);

    self.titleLabel.frame = CGRectMake(left, topY, usableW - 140, 32);
    self.resizeButton.frame = CGRectMake(w - right - 100, topY, 44, 32);
    self.closeButton.frame = CGRectMake(w - right - 50, topY, 48, 32);
    topY += 40;

    self.statusLabel.frame = CGRectMake(left, topY, usableW, 20);
    topY += 26;

    self.listHeadLabel.frame = CGRectMake(left, topY, usableW, 20);
    topY += 22;

    const CGFloat kBtnRowH = 44 + 16;
    const CGFloat kSliderRowH = 30 + 8 + 8;
    CGFloat tableH = h - topY - kBtnRowH - kSliderRowH - 8;
    if (tableH < 60) tableH = 60;
    self.table.frame = CGRectMake(0, topY, w, tableH);
    topY += tableH + 8;

    NSArray<UIButton *> *btns = self.actionButtons;
    CGFloat bw = (usableW - 8*(btns.count - 1)) / (CGFloat)btns.count;
    if (bw < 50) bw = 50;
    CGFloat bx = left;
    for (UIButton *b in btns) {
        b.frame = CGRectMake(bx, topY, bw, 44);
        bx += bw + 8;
    }
    topY += 44 + 8;

    CGFloat sliderY = topY;
    self.progressSlider.frame = CGRectMake(left, sliderY, usableW - 70, 30);
    self.rateButton.frame = CGRectMake(w - right - 60, sliderY, 60, 30);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutPanel];
}

/* ---- 拖动 ---- */
- (void)handleDrag:(UIPanGestureRecognizer *)pan {
    [self resetAutoHideTimer];
    if (!gDFHWindow) return;
    CGPoint t = [pan translationInView:self.view];
    CGRect f = gDFHWindow.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    CGRect screen = [UIScreen mainScreen].bounds;
    if (f.origin.x < 0) f.origin.x = 0;
    if (f.origin.y < 0) f.origin.y = 0;
    if (CGRectGetMaxX(f) > screen.size.width) f.origin.x = screen.size.width - f.size.width;
    if (CGRectGetMaxY(f) > screen.size.height) f.origin.y = screen.size.height - f.size.height;
    gDFHWindow.frame = f;
    [pan setTranslation:CGPointZero inView:self.view];
}

/* ---- 尺寸循环 ---- */
- (void)cycleSize {
    [self resetAutoHideTimer];
    if (!gDFHWindow) return;
    self.sizeLevel = (self.sizeLevel + 1) % 3;
    CGRect r = [UIScreen mainScreen].bounds;
    CGFloat ratios[] = { 0.6, 0.75, 0.9 };
    CGFloat ratio = ratios[self.sizeLevel];	
		CGFloat w = r.size.width * ratio;
		CGFloat h = r.size.height * ratio;
    CGRect f = gDFHWindow.frame;
    f.size = CGSizeMake(w, h);

    CGRect screen = r;
    if (f.origin.x < 0) f.origin.x = 0;
    if (f.origin.y < 0) f.origin.y = 0;
    if (CGRectGetMaxX(f) > screen.size.width) f.origin.x = screen.size.width - f.size.width;
    if (CGRectGetMaxY(f) > screen.size.height) f.origin.y = screen.size.height - f.size.height;
    gDFHWindow.frame = f;

    UIViewController *root = gDFHWindow.rootViewController;
    if (root) {
        root.view.frame = CGRectMake(0, 0, w, h);
        [root.view setNeedsLayout];
        [root.view layoutIfNeeded];
    }
    DFHLOG(@"尺寸切换 level=%ld → %.0fx%.0f", (long)self.sizeLevel, w, h);
}

/* ---- 自动隐藏 ---- */
- (void)resetAutoHideTimer {
    [self.autoHideTimer invalidate];
    self.autoHideTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:NO block:^(NSTimer *t) {
        DFHLOG(@"30s 无操作，自动隐藏（播放继续）");
        gDFHWindow.hidden = YES;
    }];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshList];
    [self resetAutoHideTimer];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.autoHideTimer invalidate];
    self.autoHideTimer = nil;
}

- (void)hidePanel {
    gDFHWindow.hidden = YES;
    [self.autoHideTimer invalidate];
    DFHLOG(@"面板隐藏（收起按钮，播放继续）");
}

- (void)sliderTouchDown {
    self.userDraggingSlider = YES;
}
- (void)sliderTouchUp {
    self.userDraggingSlider = NO;
    uint64_t total = [DFHPlayer shared].totalUs;
    if (total == 0) return;
    uint64_t target = (uint64_t)(self.progressSlider.value * (double)total);
    [[DFHPlayer shared] seekToUs:target];
    DFHLOG(@"进度条跳转 → %llu / %llu", (unsigned long long)target, (unsigned long long)total);
}

- (void)cycleRate {
    static const double rates[] = { 0.5, 1.0, 1.5, 2.0, 2.5, 3.0 };
    static const NSUInteger n = sizeof(rates)/sizeof(rates[0]);
    double cur = [DFHPlayer shared].rate;
    NSUInteger idx = 0;
    for (NSUInteger i = 0; i < n; i++) {
        if (fabs(rates[i] - cur) < 1e-6) { idx = (i + 1) % n; break; }
    }
    double next = rates[idx];
    [DFHPlayer shared].rate = next;
    [self.rateButton setTitle:[NSString stringWithFormat:@"%.1fx", next] forState:UIControlStateNormal];
    DFHLOG(@"倍速 → %.1fx", next);
}

- (void)buttonTapped:(UIButton *)b {
    [self resetAutoHideTimer];
    switch (b.tag) {
        case 0: {
            NSIndexPath *ip = self.table.indexPathForSelectedRow;
            if (ip && ip.row < self.midiFiles.count) DFHPlayMidiFile(self.midiFiles[ip.row]);
            break;
        }
       case 1: {
            [[DFHPlayer shared] pauseAndSave];
            self.statusLabel.text = @"已停止（进度已存）";
            break;
        }
         case 2: DFHReplayLast(); break;
        case 3: [self importMidi]; break;
        case 4: [self openCalibration]; break;
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
    if (gDFHWindow && gDFHWindow.hidden) gDFHWindow.hidden = NO;

    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeMIDI]
                                                                     asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    if (urls.count == 0) return;

    NSURL *src = urls.firstObject;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *destDir = DFHMidiDirectory();
    NSString *name = src.lastPathComponent;
    NSString *dest = [destDir stringByAppendingPathComponent:name];

    /* 重名加 -1 后缀 */
    if ([fm fileExistsAtPath:dest]) {
        NSString *base = [name stringByDeletingPathExtension];
        NSString *ext = name.pathExtension;
        for (NSInteger i = 1; i < 1000; i++) {
            NSString *candidate = [NSString stringWithFormat:@"%@-%ld.%@", base, (long)i, ext];
            NSString *p = [destDir stringByAppendingPathComponent:candidate];
            if (![fm fileExistsAtPath:p]) { dest = p; name = candidate; break; }
        }
    }

    BOOL srcAccess = [src startAccessingSecurityScopedResource];
    NSError *err = nil;
    BOOL ok = [fm copyItemAtURL:src toURL:[NSURL fileURLWithPath:dest] error:&err];
    if (srcAccess) [src stopAccessingSecurityScopedResource];

    if (ok) {
        [self refreshList];
        self.statusLabel.text = [NSString stringWithFormat:@"已导入 %@", name];
        DFHLOG(@"导入成功 %@ → %@", src.path, dest);
    } else {
        self.statusLabel.text = @"导入失败";
        DFHLOG(@"导入失败 %@：%@", src.path, err.localizedDescription);
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    self.statusLabel.text = @"已取消导入";
}

- (void)openCalibration {
    __weak typeof(self) weakSelf = self;
    DFHCalibrationViewController *cal = [[DFHCalibrationViewController alloc] initWithFinishBlock:^{
        [weakSelf refreshList];
    }];
    [self presentViewController:cal animated:YES completion:nil];
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
    [self resetAutoHideTimer];
    DFHPlayMidiFile(self.midiFiles[ip.row]);
}

@end

/* ---------------- 悬浮窗管理 ---------------- */
static void DFHShowPanel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gDFHWindow) {
            CGRect r = [UIScreen mainScreen].bounds;
            UIWindowScene *targetScene = nil;
            if (@available(iOS 13.0, *)) {
                for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if (scene.activationState != UISceneActivationStateForegroundActive) continue;
                    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                    if ([scene.session.role containsString:@"SystemAperture"]) continue;
                    targetScene = (UIWindowScene *)scene;
                    break;
                }
            }
            if (targetScene) {
                r = targetScene.coordinateSpace.bounds;
            }
            CGFloat w = r.size.width * 0.75;
            CGFloat h = r.size.height * 0.7;
            CGRect wr = CGRectMake((r.size.width - w)/2, (r.size.height - h)/2, w, h);

            gDFHWindow = [[DFHPanelWindow alloc] initWithFrame:wr];
            gDFHWindow.autoresizingMask = UIViewAutoresizingNone;
            if (targetScene) {
                gDFHWindow.windowScene = targetScene;
            }
            gDFHWindow.rootViewController = [DFHPanelViewController new];
            gDFHWindow.backgroundColor = [UIColor clearColor];
            DFHLOG(@"创建窗口: %@ windowScene=%@",
                   NSStringFromCGRect(wr), gDFHWindow.windowScene);
        }
        gDFHWindow.windowLevel = UIWindowLevelAlert + 1000;
        gDFHWindow.hidden = NO;
        DFHLOG(@"ShowPanel: window=%@ hidden=%d level=%.0f windowScene=%@",
               gDFHWindow, gDFHWindow.hidden, gDFHWindow.windowLevel, gDFHWindow.windowScene);
    });
}

static void DFHHidePanel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gDFHWindow) gDFHWindow.hidden = YES;
        DFHLOG(@"HidePanel（播放继续）");
    });
}

/* ---------------- 临时 Alert Window（功能 1 弹窗挂载） ---------------- */
static UIWindow *gDFHAlertWindow = nil;

static void DFHShowResumeAlertIfNeeded(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *lastMidi = [ud objectForKey:@"lastMidi"];
    uint64_t lastUs = [[ud objectForKey:@"lastPlayedUs"] unsignedLongLongValue];
    if (lastMidi.length == 0 || lastUs == 0) return;

    NSString *path = [DFHMidiDirectory() stringByAppendingPathComponent:lastMidi];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    NSError *err = nil;
    DFHMIDIResult *res = [DFHMIDIParser parseFileAtPath:path error:&err];
    if (!res) return;

    double bpm = res.bpm > 0 ? res.bpm : DFH_DEFAULT_BPM;
    double scale = bpm / 120.0;
    uint64_t totalUs = (uint64_t)((double)res.totalDurationUs / scale);
    if (lastUs > totalUs) lastUs = totalUs;

    uint64_t sec = lastUs / 1000000ULL;
    NSString *posText = [NSString stringWithFormat:@"%02llu:%02llu",
                         (unsigned long long)(sec / 60), (unsigned long long)(sec % 60)];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gDFHAlertWindow) {
            CGRect r = [UIScreen mainScreen].bounds;
            gDFHAlertWindow = [[UIWindow alloc] initWithFrame:r];
            if (@available(iOS 13.0, *)) {
                for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if (scene.activationState == UISceneActivationStateForegroundActive &&
                        [scene isKindOfClass:[UIWindowScene class]]) {
                        gDFHAlertWindow.windowScene = (UIWindowScene *)scene;
                        break;
                    }
                }
            }
            UIViewController *root = [UIViewController new];
            root.view.backgroundColor = [UIColor clearColor];
            gDFHAlertWindow.rootViewController = root;
        }
        gDFHAlertWindow.windowLevel = UIWindowLevelAlert + 2000;
        gDFHAlertWindow.hidden = NO;

        UIViewController *root = gDFHAlertWindow.rootViewController;
        if (!root || root.presentedViewController) return;

        NSString *msg = [NSString stringWithFormat:@"上次播放《%@》到 %@，是否继续？", lastMidi, posText];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"继续播放？"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
        __weak UIWindow *weakAlertWin = gDFHAlertWindow;
        [alert addAction:[UIAlertAction actionWithTitle:@"继续" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a;
            dispatch_async(dispatch_get_main_queue(), ^{
                DFHPlayer *p = [DFHPlayer shared];
                p.currentMidiName = lastMidi;
                [p playResult:res fromUs:lastUs];
                [ud setObject:@(lastUs) forKey:@"lastPlayedUs"];
                [ud synchronize];
            });
            if (weakAlertWin) { weakAlertWin.hidden = YES; }
            gDFHAlertWindow = nil;
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"从头" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a;
            dispatch_async(dispatch_get_main_queue(), ^{
                DFHPlayer *p = [DFHPlayer shared];
                p.currentMidiName = lastMidi;
                [p playResult:res fromUs:0];
                [ud setObject:@(0) forKey:@"lastPlayedUs"];
                [ud synchronize];
            });
            if (weakAlertWin) { weakAlertWin.hidden = YES; }
            gDFHAlertWindow = nil;
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
            (void)a;
            if (weakAlertWin) { weakAlertWin.hidden = YES; }
            gDFHAlertWindow = nil;
        }]];
        [root presentViewController:alert animated:YES completion:nil];
    });
}

static BOOL DFHPanelVisible(void) {
    return gDFHWindow && !gDFHWindow.hidden;
}

/* 统一处理一次“音量下”事件：只在三角洲前台拦截，并确保面板显示。
 * 返回 YES 表示已拦截（不要继续调 %orig）。 */
static BOOL DFHHandleVolumeDownFrom(const char *where) {
    NSString *bid = DFHCurrentFrontmostBundleID();
    BOOL df = DFHIsDeltaForceForeground();
    BOOL visible = DFHPanelVisible();
    DFHLOG(@"音量下事件命中[%s] 前台=%@ 三角洲=%d 面板可见=%d",
           where, bid ?: @"nil", df, visible);

    if (!df) return NO;               /* 非三角洲：放行音量 */

    if (visible) {
        DFHHidePanel();
        DFHLOG(@"[%s] 面板可见 → 隐藏（播放继续）", where);
    } else {
        DFHShowPanel();
        DFHLOG(@"[%s] 面板隐藏 → 显示", where);
    }
    return YES;                       /* 吞掉音量 */
}

/* ---------------- 音量下键多层 hook ---------------- */

%group SpringBoardVolumeHook
%hook SpringBoard

- (BOOL)_volumeChanged:(struct __IOHIDEvent *)event {
    BOOL df = DFHIsDeltaForceForeground();
    DFHLOG(@"SpringBoard _volumeChanged: 前台=%@ 三角洲=%d 面板可见=%d",
           DFHCurrentFrontmostBundleID() ?: @"nil", df, DFHPanelVisible());
    return %orig;
}

%end
%end

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

		/* SpringBoard 重启时清空日志 */
    NSString *logPath = @"/var/mobile/Documents/dfh.log";
    [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];

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

    /* 前后台通知（SpringBoard 里也能收到） */
    NSNotificationCenter *localNC = [NSNotificationCenter defaultCenter];
    [localNC addObserverForName:UIApplicationDidEnterBackgroundNotification
                         object:nil
                          queue:[NSOperationQueue mainQueue]
                     usingBlock:^(NSNotification *note) {
        (void)note;
        DFHPlayer *p = [DFHPlayer shared];
        if (p.isPlaying) {
            DFHLOG(@"三角洲退后台 → pauseAndSave");
            [p pauseAndSave];
        }
    }];
    [localNC addObserverForName:UIApplicationDidBecomeActiveNotification
                         object:nil
                          queue:[NSOperationQueue mainQueue]
                     usingBlock:^(NSNotification *note) {
        (void)note;
        if (!DFHIsDeltaForceForeground()) return;
        if (gDFHWindow && !gDFHWindow.hidden &&
            [gDFHWindow.rootViewController isKindOfClass:[DFHPanelViewController class]]) {
            [(DFHPanelViewController *)gDFHWindow.rootViewController refreshList];
        }
        DFHShowResumeAlertIfNeeded();
    }];

    %init(SpringBoardVolumeHook);
    %init(VolumeControlHook);

    DFHLOG(@"DeltaHarmonica 已注入 SpringBoard（音量下键唤起面板，仅三角洲生效）");
}