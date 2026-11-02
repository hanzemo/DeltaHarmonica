#import "DFHPlayer.h"
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <unistd.h>

/* =====================================================================
 * DFHPlayer.m
 * 演奏调度器实现
 *
 * 时序策略：
 *  用 dispatch 后台串行队列 + 每步 sleep 前计算"下一个事件绝对时间"，
 *  派发按键。mach_absolute_time 经 mach_timebase_info 精确换算为 us，
 *  再除以 rate 得到实际等待时间（倍速）。
 *
 * 线程安全：
 *  _cancel / _paused / _playing / _rate / _currentUs / _totalUs / _runToken
 *  全部在 @synchronized(self) 下读写。
 *  runResult: 在后台队列运行，只读局部快照，写状态时进同步块。
 *
 * 进度尺度：
 *  内部 _notes 是「BPM 归一化到 120」后的副本（startUs/durationUs 已缩放），
 *  _totalUs = result.totalDurationUs / tempoScale。
 *  对外 onProgress / seekToUs: / currentUs / lastPlayedUs 全部用此尺度。
 * ===================================================================== */

/* ---------------- DFHLOG（与 Tweak.xm 一致，已知坑 3） ---------------- */
#define DFHLOG(fmt, ...) do { \
    NSString *s = [NSString stringWithFormat:@"[DFH] " fmt "\n", ##__VA_ARGS__]; \
    NSString *p = @"/var/mobile/Documents/dfh.log"; \
    FILE *f = fopen(p.UTF8String, "a"); \
    if (f) { fputs(s.UTF8String, f); fclose(f); } \
} while(0)

/* 音区切换键编号（与 DFHCore 标定编号一致） */
static const NSInteger kDFHRegKey[] = {
    8,   /* DFHRegisterFlat    -> 低音区切换键 */
    9,   /* DFHRegisterNatural -> 中音区切换键 */
    10,  /* DFHRegisterSharp   -> 高音区切换键 */
};

/* 半音键编号 */
static const NSInteger kDFHHalfKey = 11;

/* 音符键编号：度数 1-7 -> 标定编号 0-6，度数 8（高音 do）-> 标定编号 7 */
static NSInteger DFHNoteKeyForDegree(int degree) {
    if (degree >= 1 && degree <= 7) return degree - 1;
    if (degree == 8) return 7;
    return 0;
}

/* ---------------- mach_timebase 精确换算（已知坑 1） ---------------- */
static uint64_t DFHTicksToUs(uint64_t ticks) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    /* ticks * numer / denom = 纳秒；再 /1000 = 微秒。
     * 先乘后除避免精度损失；用 __uint128_t 防溢出。 */
    __uint128_t ns = (__uint128_t)ticks * tb.numer / tb.denom;
    return (uint64_t)(ns / 1000);
}

/* 进度保存 key（与 Tweak.xm 共用） */
static NSString * const kDFHKeyLastMidi     = @"lastMidi";
static NSString * const kDFHKeyLastPlayedUs = @"lastPlayedUs";

@implementation DFHPlayer {
    dispatch_queue_t   _queue;
    BOOL               _cancel;
    BOOL               _paused;
    BOOL               _playing;
    double             _rate;
    DFHRegister        _currentReg;

    /* 当前曲目（归一化后副本） */
    NSArray<DFHNoteEvent *> *_notes;
    uint64_t            _totalUs;
    uint64_t            _currentUs;

    /* 当前曲目文件名（pauseAndSave 写 lastMidi 用） */
    NSString           *_currentMidiName;

    /* 每次 playResult/seek 递增，旧 run 看到 token 变化即退出 */
    NSUInteger          _runToken;

    /* run 的绝对时间基准（mach ticks），seek 时重置 */
    uint64_t            _runStartTicks;
    /* run 的起始时间轴位置（归一化 us），seek 时非 0 */
    uint64_t            _runBaseUs;
}

+ (DFHPlayer *)shared {
    static DFHPlayer *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [DFHPlayer new]; });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        _queue = dispatch_queue_create("com.hanzemo.deltaharmonica.player", DISPATCH_QUEUE_SERIAL);
        _cancel = NO;
        _paused = NO;
        _playing = NO;
        _rate = 1.0;
        _currentReg = DFHRegisterNatural;
        _notes = @[];
        _totalUs = 0;
        _currentUs = 0;
        _runToken = 0;
        _runStartTicks = 0;
        _runBaseUs = 0;
    }
    return self;
}

- (BOOL)isPlaying {
    @synchronized (self) { return _playing; }
}

- (uint64_t)currentUs {
    @synchronized (self) { return _currentUs; }
}

- (uint64_t)totalUs {
    @synchronized (self) { return _totalUs; }
}

- (NSString *)currentMidiName {
    @synchronized (self) { return _currentMidiName; }
}

- (void)setCurrentMidiName:(NSString *)currentMidiName {
    @synchronized (self) { _currentMidiName = [currentMidiName copy]; }
}

- (double)rate {
    @synchronized (self) { return _rate; }
}

- (void)setRate:(double)rate {
    if (rate < 0.5) rate = 0.5;
    if (rate > 3.0) rate = 3.0;

    BOOL playing;
    uint64_t cur;
    @synchronized (self) {
        if (fabs(_rate - rate) < 1e-9) return;
        _rate = rate;
        playing = _playing;
        cur = _currentUs;
    }
    if (playing) {
        /* 从当前位置重建时间基准，不停播 */
        [self seekToUs:cur];
    }
}

- (void)stop {
    @synchronized (self) {
        _cancel = YES;
        _paused = NO;
        _playing = NO;
        _runToken++;
        _currentUs = 0;
    }
}

- (void)pause {
    @synchronized (self) { _paused = YES; }
}

- (void)resume {
    @synchronized (self) { _paused = NO; }
}

- (void)pauseAndSave {
    uint64_t cur = 0;
    NSString *name = nil;
    @synchronized (self) {
        _paused = YES;
        _playing = NO;
        _cancel = YES;
        _runToken++;
        cur = _currentUs;
        name = _currentMidiName;
    }
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:@(cur) forKey:kDFHKeyLastPlayedUs];
    if (name.length) [ud setObject:name forKey:kDFHKeyLastMidi];
    [ud synchronize];
    DFHLOG(@"pauseAndSave: lastMidi=%@ lastPlayedUs=%llu", name, (unsigned long long)cur);
}

/* ------------------------------------------------------------------
 * BPM 归一化：复制 notes 并缩放（不改 result 本身）
 * ------------------------------------------------------------------ */
static NSArray<DFHNoteEvent *> *DFHNormalizeNotes(DFHMIDIResult *result, double *outTotalUs) {
    double bpm = result.bpm;
    if (bpm <= 0) bpm = DFH_DEFAULT_BPM;
    double tempoScale = bpm / 120.0;
    if (tempoScale <= 0) tempoScale = 1.0;

    NSMutableArray<DFHNoteEvent *> *out = [NSMutableArray arrayWithCapacity:result.notes.count];
    for (DFHNoteEvent *n in result.notes) {
        DFHNoteEvent *c = [DFHNoteEvent new];
        c.pitch      = n.pitch;
        c.channel    = n.channel;
        c.velocity   = n.velocity;
        c.startUs    = (uint64_t)((double)n.startUs / tempoScale);
        c.durationUs = (uint64_t)((double)n.durationUs / tempoScale);
        [out addObject:c];
    }
    if (outTotalUs) *outTotalUs = (uint64_t)((double)result.totalDurationUs / tempoScale);
    DFHLOG(@"BPM 归一化: bpm=%.1f scale=%.3f notes=%lu totalUs=%llu",
           bpm, tempoScale, (unsigned long)out.count,
           (unsigned long long)(outTotalUs ? *outTotalUs : 0));
    return out;
}

/* ------------------------------------------------------------------
 * 播放入口
 * ------------------------------------------------------------------ */

- (void)playResult:(DFHMIDIResult *)result {
    [self playResult:result fromUs:0];
}

- (void)playResult:(DFHMIDIResult *)result fromUs:(uint64_t)fromUs {
    uint64_t total = 0;
    NSArray<DFHNoteEvent *> *norm = DFHNormalizeNotes(result, &total);
    if (fromUs > total) fromUs = total;

    NSUInteger token;
    double rate;
    @synchronized (self) {
        _cancel = NO;
        _paused = NO;
        _playing = YES;
        _notes = norm;
        _totalUs = total;
        _currentUs = fromUs;
        _runBaseUs = fromUs;
        _runStartTicks = mach_absolute_time();
        _runToken++;
        token = _runToken;
        rate = _rate;
    }

    DFHLOG(@"playResult:fromUs=%llu total=%llu rate=%.2f notes=%lu",
           (unsigned long long)fromUs, (unsigned long long)total,
           rate, (unsigned long)norm.count);

    dispatch_async(_queue, ^{
        [self runNotes:norm fromUs:fromUs totalUs:total token:token];
    });
}

- (void)seekToUs:(uint64_t)us {
    NSArray<DFHNoteEvent *> *notes;
    uint64_t total;
    BOOL playing;
    double rate;
    @synchronized (self) {
        notes = _notes;
        total = _totalUs;
        playing = _playing;
        rate = _rate;
        if (!playing || notes.count == 0) return;
        if (us > total) us = total;
        _cancel = YES;            /* 旧 run 退出 */
        _runToken++;
        _currentUs = us;
        _runBaseUs = us;
        _runStartTicks = mach_absolute_time();
        _cancel = NO;
        _paused = NO;
    }

    NSUInteger token;
    @synchronized (self) { token = _runToken; }

    [[NSUserDefaults standardUserDefaults] setObject:@(us) forKey:kDFHKeyLastPlayedUs];
    DFHLOG(@"seekToUs=%llu (total=%llu rate=%.2f)",
           (unsigned long long)us, (unsigned long long)total, rate);

    dispatch_async(_queue, ^{
        [self runNotes:notes fromUs:us totalUs:total token:token];
    });
}

/* ------------------------------------------------------------------
 * 实时等待：绝对时钟校准 + 暂停 + 倍速
 * 目标时间轴 us -> 实际等待 (targetUs - baseUs) / rate
 * ------------------------------------------------------------------ */

- (BOOL)sleepUntilTimelineUs:(uint64_t)targetUs token:(NSUInteger)token {
    while (YES) {
        NSUInteger curToken;
        BOOL cancel, paused;
        uint64_t startTicks, baseUs;
        double rate;
        @synchronized (self) {
            curToken = _runToken;
            cancel = _cancel;
            paused = _paused;
            startTicks = _runStartTicks;
            baseUs = _runBaseUs;
            rate = _rate;
        }
        if (cancel || curToken != token) return NO;

        if (paused) {
            usleep(100 * 1000);
            continue;
        }

        uint64_t nowTicks = mach_absolute_time();
        uint64_t elapsedUs = DFHTicksToUs(nowTicks - startTicks);
        /* 时间轴已走 = baseUs + elapsedUs * rate */
        uint64_t walkedUs = baseUs + (uint64_t)((double)elapsedUs * rate);

        if (walkedUs >= targetUs) return YES;

        uint64_t remainTimelineUs = targetUs - walkedUs;
        /* 换算实际等待：remainTimelineUs / rate */
        double remainRealUs = (double)remainTimelineUs / rate;
        uint32_t sleepUs = (uint32_t)MIN((uint64_t)remainRealUs, 50000ULL);
        if (sleepUs == 0) sleepUs = 1;
        usleep(sleepUs);
    }
}

- (void)updateCurrentUs:(uint64_t)us token:(NSUInteger)token {
    uint64_t total = 0;
    @synchronized (self) {
        if (_runToken != token) return;
        _currentUs = us;
        total = _totalUs;
    }
    if (self.onProgress) {
        void (^cb)(uint64_t, uint64_t) = self.onProgress;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (cb) cb(us, total);
        });
    }
}

/* ------------------------------------------------------------------
 * 演奏主流程
 * ------------------------------------------------------------------ */

- (void)runNotes:(NSArray<DFHNoteEvent *> *)notes
          fromUs:(uint64_t)fromUs
         totalUs:(uint64_t)totalUs
           token:(NSUInteger)token {
    if (notes.count == 0) {
        [self finishRun:token];
        return;
    }

    DFHRegister lastReg = DFHRegisterNatural;
    BOOL lastHalf = NO;
    BOOL hasPrevReg = NO;
    BOOL hasPrevHalf = NO;

    for (NSUInteger i = 0; i < notes.count; i++) {
        DFHNoteEvent *n = notes[i];
        /* 跳过 fromUs 之前的音符（seek 时） */
        if (n.startUs + n.durationUs <= fromUs) {
            DFHPitchMap m0 = [DFHMIDIParser pitchMapFor:n.pitch];
            if (m0.degree != 8) {
                if (!hasPrevReg || m0.reg != lastReg) {
                    /* 不注入，仅记录状态，保证首个可发音符音区正确 */
                }
                lastReg = m0.reg;
                lastHalf = m0.accidental;
                hasPrevReg = YES;
                hasPrevHalf = YES;
            }
            continue;
        }
        /* 起始在 fromUs 之前但未结束的音符：从 fromUs 起播 */
        uint64_t noteStart = n.startUs;
        if (noteStart < fromUs) noteStart = fromUs;

        if (![self sleepUntilTimelineUs:noteStart token:token]) { [self finishRun:token]; return; }

        DFHPitchMap m = [DFHMIDIParser pitchMapFor:n.pitch];
        BOOL useIndependentHighDo = (m.degree == 8);

        if (!useIndependentHighDo && (!hasPrevReg || m.reg != lastReg)) {
            if (![self sleepUntilTimelineUs:noteStart token:token]) { [self finishRun:token]; return; }
            DFHTapKey(kDFHRegKey[m.reg], 50.0);
            if (![self sleepUntilTimelineUs:noteStart + 120000 token:token]) { [self finishRun:token]; return; }
            lastReg = m.reg;
            hasPrevReg = YES;
        }

        if (!useIndependentHighDo && (!hasPrevHalf || m.accidental != lastHalf)) {
            if (![self sleepUntilTimelineUs:noteStart token:token]) { [self finishRun:token]; return; }
            DFHTapKey(kDFHHalfKey, 50.0);
            if (![self sleepUntilTimelineUs:noteStart + 80000 token:token]) { [self finishRun:token]; return; }
            lastHalf = m.accidental;
            hasPrevHalf = YES;
        }

        double noteMs = (double)n.durationUs / 1000.0;
        double holdMs = noteMs - 30.0;
        if (holdMs < DFH_MIN_HOLD_MS) holdMs = DFH_MIN_HOLD_MS;
        if (holdMs > DFH_MAX_HOLD_MS) holdMs = DFH_MAX_HOLD_MS;

        DFHTapKey(DFHNoteKeyForDegree(m.degree), holdMs);

        uint64_t noteEnd = n.startUs + n.durationUs;
        [self updateCurrentUs:noteEnd token:token];
    }

    [self updateCurrentUs:totalUs token:token];
    [self finishRun:token];
}

- (void)finishRun:(NSUInteger)token {
    BOOL wasPlaying = NO;
    @synchronized (self) {
        if (_runToken != token) return;   /* 已被 seek/stop 取代 */
        if (_playing) {
            wasPlaying = YES;
            _playing = NO;
        }
        _currentUs = _totalUs;
    }
    if (wasPlaying) {
        NSString *name = nil;
        @synchronized (self) { name = _currentMidiName; }
        [[NSUserDefaults standardUserDefaults] setObject:@(0) forKey:kDFHKeyLastPlayedUs];
        [[NSUserDefaults standardUserDefaults] synchronize];
        DFHLOG(@"自然结束，lastPlayedUs=0（lastMidi 保留=%@）", name);
        uint64_t total = 0;
        @synchronized (self) { total = _totalUs; }
        if (self.onProgress) {
            void (^cb)(uint64_t, uint64_t) = self.onProgress;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (cb) cb(total, total);
            });
        }
    }
}

@end