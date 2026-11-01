#import "DFHPlayer.h"
#import <UIKit/UIKit.h>

/* =====================================================================
 * DFHPlayer.m
 * 演奏调度器实现
 *
 * 时序策略：
 *  用 dispatch 后台串行队列 + 每步 sleep 前计算"下一个事件绝对时间"，派发按键。
 *  实时校准：记录起始 mach_absolute_time，每步根据 elapsed 计算 sleep 补偿，
 *  避免累积 drift（长曲目跑偏）。
 * ===================================================================== */

/* 音区切换键编号（与 DFHCore 标定编号一致） */
static const NSInteger kDFHRegKey[] = {
    8,   /* DFHRegisterFlat    -> 低音区切换键 */
    9,   /* DFHRegisterNatural -> 中音区切换键 */
    10,  /* DFHRegisterSharp   -> 高音区切换键 */
};

/* 半音键编号 */
static const NSInteger kDFHHalfKey = 11;

/* 音符键编号：度数 1-8 -> 标定编号 0-7（8=高音 do 与 i 共用） */
static NSInteger DFHNoteKeyForDegree(int degree) {
    if (degree >= 1 && degree <= 7) return degree - 1;
    if (degree == 8) return 7;            /* 高音 do 用 7 号键（i） */
    return 0;
}

@implementation DFHPlayer {
    dispatch_queue_t   _queue;
    BOOL               _cancel;
    BOOL               _paused;
    BOOL               _playing;
    DFHRegister        _currentReg;
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
        _currentReg = DFHRegisterNatural;
    }
    return self;
}

- (BOOL)isPlaying { return _playing; }

- (void)stop {
    _cancel = YES;
    _paused = NO;
    _playing = NO;
}

- (void)pause { _paused = YES; }

- (void)resume { _paused = NO; }

/* ------------------------------------------------------------------
 * 演奏主流程
 * ------------------------------------------------------------------ */

- (void)playResult:(DFHMIDIResult *)result {
    [self stop];
    _cancel = NO;
    _playing = YES;

    dispatch_async(_queue, ^{
        [self runResult:result];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_playing = NO;
            if (self.onProgress) self.onProgress(result.totalDurationUs, result.totalDurationUs);
        });
    });
}

/* 实时等待：按绝对时钟校准，支持暂停 */
- (void)sleepUntilSinceStart:(uint64_t)targetUs startTime:(uint64_t)startNanos {
    while (YES) {
        if (_cancel) return;

        if (_paused) {
            /* 暂停时睡 100ms 轮询，等待 resume */
            usleep(100 * 1000);
            continue;
        }

        uint64_t now = mach_absolute_time();
        uint64_t elapsedNanos = now - startNanos;
        /* mach_absolute_time 单位不一定纳秒，但用于相对比较足够；
         * 这里直接用差值，与 targetUs 需要同一尺度换算。 */
        /* 近似：1 us ≈ 1 纳秒尺度，差距用比例修正不可靠，直接按 us 近似 */
        uint64_t elapsedUs = elapsedNanos / 1000;

        if (elapsedUs >= targetUs) return;

        uint64_t remainUs = targetUs - elapsedUs;
        uint32_t sleepUs = (uint32_t)MIN(remainUs, 50000ULL); /* 最多睡 50ms，保证暂停响应 */
        usleep(sleepUs);
    }
}

- (void)runResult:(DFHMIDIResult *)result {
    NSArray<DFHNoteEvent *> *notes = result.notes;
    if (notes.count == 0) return;

    uint64_t startNanos = mach_absolute_time();
    DFHRegister lastReg = DFHRegisterNatural;

    uint64_t lastNoteEndUs = 0;

    for (NSUInteger i = 0; i < notes.count; i++) {
        if (_cancel) break;
        DFHNoteEvent *n = notes[i];

        /* 等待到本次音符起始时刻 */
        [self sleepUntilSinceStart:n.startUs startTime:startNanos];
        if (_cancel) break;

        /* 音高 -> 音区/音名/半音 */
        DFHPitchMap m = [DFHMIDIParser pitchMapFor:n.pitch];

        /* 若音区改变，先按调性切换键，等待切换间隙 */
        if (m.reg != lastReg) {
            if (_cancel) break;
            DFHTapKey(kDFHRegKey[m.reg], 50.0);   /* 切换键短按 50ms */
            [self sleepUntilSinceStart:n.startUs + 120000 startTime:startNanos]; /* 120ms 切换间隙 */
            if (_cancel) break;
            lastReg = m.reg;
        }

        /* 计算按押时长：音符时长 - 30ms 留隙，夹在 30~60ms */
        double noteMs = (double)n.durationUs / 1000.0;
        double holdMs = noteMs - 30.0;
        if (holdMs < DFH_MIN_HOLD_MS) holdMs = DFH_MIN_HOLD_MS;
        if (holdMs > DFH_MAX_HOLD_MS) holdMs = DFH_MAX_HOLD_MS;

        /* 半音：先按半音键再按音符（三角洲半音是升半音语义） */
        if (m.accidental) {
            DFHTapKey(kDFHHalfKey, 50.0);
            [self sleepUntilSinceStart:n.startUs + 60000 startTime:startNanos]; /* 60ms 间隙 */
            if (_cancel) break;
        }

        /* 按下音符键 */
        DFHTapKey(DFHNoteKeyForDegree(m.degree), holdMs);

        uint64_t noteEndUs = n.startUs + n.durationUs;
        if (noteEndUs > lastNoteEndUs) lastNoteEndUs = noteEndUs;

        if (self.onProgress) {
            uint64_t played = n.startUs + n.durationUs;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.onProgress) self.onProgress(played, result.totalDurationUs);
            });
        }
    }
}

@end
