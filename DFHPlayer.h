#import <Foundation/Foundation.h>
#import "DFHCore.h"
#import "DFHMIDIParser.h"

NS_ASSUME_NONNULL_BEGIN

/* =====================================================================
 * DFHPlayer.h
 * 演奏调度器：把已解析的 MIDI 音符序列，按时间轴转换成按键事件。
 *
 * 与安卓版 DF-NoctReed 对齐的演奏逻辑：
 *  - 音区切换：播放每个音符前，若音区改变，先注入"调性切换键"点击，
 *    等待 120ms 切换间隙后，再按下音符键。
 *  - 连音（legato）/ 延音：按下音符键后 hold 住 holdMs，
 *    holdMs = noteMs - 30ms，避免相邻音符串音。
 *  - 十六分音符精度限制：hold 时长被约束在 30~60ms 区间，
 *    高 BPM 下可能连音/漏音，这是系统调度精度的固有瓶颈。
 * ===================================================================== */

@interface DFHPlayer : NSObject

@property (class, nonatomic, readonly) DFHPlayer *shared;

/* 开始播放某个 MIDI 结果；异步，在后台队列按时间轴派发 */
- (void)playResult:(DFHMIDIResult *)result;

/* 停止播放 */
- (void)stop;

/* 是否正在播放 */
@property (nonatomic, readonly) BOOL isPlaying;

/* 暂停 / 恢复 */
- (void)pause;
- (void)resume;

/* 播放进度回调（可选，用于 UI/悬浮球），runningUnit 为已播 microsecond */
@property (nonatomic, copy, nullable) void (^onProgress)(uint64_t playedUs, uint64_t totalUs);

@end

NS_ASSUME_NONNULL_END
