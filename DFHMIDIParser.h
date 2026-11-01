#import <Foundation/Foundation.h>
#import "DFHCore.h"

NS_ASSUME_NONNULL_BEGIN

/* =====================================================================
 * DFHMIDIParser.h
 * .mid（标准 MIDI 文件）解析：从音符事件序列 -> 口琴演奏指令序列
 *
 * 设计目标（与 DeltaHarmonica 对齐）：
 *  1. 支持 SMF 类型 0（单轨）与类型 1（多轨，自动挑旋律轨 / 合并）
 *  2. 提取 note on/off -> 音符(pitch + 起止时刻)，合并成"音高 + 时长"
 *  3. 解析 Tempo meta 事件 -> 每拍微秒数 -> 实时 BPM
 *  4. 音高(pitch)映射到 三角洲口琴 的「音区 + 音名 + 半音记号」
 *     - 覆盖范围 C4(60) ~ C7(96)，共 38 个半音键位
 *     - 超界音符：取整/削波（见 .m 实现）
 * ===================================================================== */

/* 解析后的单个音符事件 */
@interface DFHNoteEvent : NSObject
@property (nonatomic) uint8_t   pitch;      /* MIDI 音高 0-127 */
@property (nonatomic) uint64_t  startUs;    /* 起始时刻（微秒，相对轨道起点） */
@property (nonatomic) uint64_t  durationUs; /* 时长（微秒） */
@property (nonatomic) uint32_t  channel;    /* MIDI 通道 */
@property (nonatomic) uint8_t   velocity;   /* 力度 */
@end

@interface DFHMIDIResult : NSObject
@property (nonatomic, copy)   NSArray<DFHNoteEvent *> *notes;
@property (nonatomic) double  bpm;                 /* 解析出的平均/起始 BPM */
@property (nonatomic) uint64_t totalDurationUs;    /* 总时长 */
@property (nonatomic) uint16_t format;             /* SMF 格式 0/1/2 */
@property (nonatomic) uint16_t trackCount;
@end

@interface DFHMIDIParser : NSObject

/* 从文件解析；返回 nil 并填 *error 若失败 */
+ (nullable DFHMIDIResult *)parseFileAtPath:(NSString *)path error:(NSError **)error;

/* 从内存数据解析 */
+ (nullable DFHMIDIResult *)parseData:(NSData *)data error:(NSError **)error;

@end

/* ---------- 音高映射结构（供 DFHPlayer 使用） ---------- */
typedef struct {
    DFHRegister reg;        /* 音区 */
    int         degree;     /* 音名度数 1=do..7=si, 8=高音do */
    BOOL        accidental; /* 是否半音 */
} DFHPitchMap;

@interface DFHMIDIParser (PitchMapping)
/* 音高 -> 口琴键位映射 */
+ (DFHPitchMap)pitchMapFor:(uint8_t)pitch;
@end

NS_ASSUME_NONNULL_END
