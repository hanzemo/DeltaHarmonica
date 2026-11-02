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
 *  - 十六分音符精度限制：hold 时长被约束在 30~60ms 区间。
 *
 * 时间轴约定（重要）：
 *  - 所有对外暴露的 us（onProgress、seekToUs:、lastPlayedUs）都是
 *    「BPM 归一化到 120 后」的尺度，与进度条同一尺度。
 *  - rate（倍速）只影响实际等待时间，不改变时间轴尺度。
 * ===================================================================== */

@interface DFHPlayer : NSObject

@property (class, nonatomic, readonly) DFHPlayer *shared;

/* 从 0 开始播放某个 MIDI 结果；异步，在后台队列按时间轴派发 */
- (void)playResult:(DFHMIDIResult *)result;

/* 从归一化时间轴位置 fromUs 开始播放（fromUs=0 等价 playResult:） */
- (void)playResult:(DFHMIDIResult *)result fromUs:(uint64_t)fromUs;

/* 停止播放（不保存进度；调用方自行处理 lastPlayedUs） */
- (void)stop;

/* 暂停 / 恢复（不保存进度） */
- (void)pause;
- (void)resume;

/* 暂停并保存进度到 NSUserDefaults（lastMidi + lastPlayedUs）。
 * lastMidi 由调用方在 playResult 前写入；本方法只写 lastPlayedUs。 */
- (void)pauseAndSave;

/* 跳转到归一化时间轴位置 us 继续播放（保持 rate 和 BPM 归一化）。
 * 若未在播放则不动作。跳转后 lastPlayedUs 同步更新。 */
- (void)seekToUs:(uint64_t)us;

/* 是否正在播放 */
@property (nonatomic, readonly) BOOL isPlaying;

/* 倍速 0.5–3.0，默认 1.0。播放中改变会从当前位置重建时间基准，不停播。 */
@property (nonatomic, assign) double rate;

/* 当前归一化时间轴位置（us），未播放时为 0 */
@property (nonatomic, readonly) uint64_t currentUs;

/* 当前曲目文件名（用于 pauseAndSave 写 lastMidi） */
@property (nonatomic, copy, nullable) NSString *currentMidiName;

/* 当前曲目归一化总时长（us），未播放时为 0 */
@property (nonatomic, readonly) uint64_t totalUs;

/* 播放进度回调（可选，用于 UI/悬浮球）。
 * playedUs / totalUs 均为归一化时间轴尺度（BPM→120）。 */
@property (nonatomic, copy, nullable) void (^onProgress)(uint64_t playedUs, uint64_t totalUs);

@end

NS_ASSUME_NONNULL_END