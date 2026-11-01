#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/* =====================================================================
 * DFHCore.h
 * 三角洲行动 · 守夜人口琴 自动演奏插件核心（SpringBoard 注入版）
 *
 * 注入目标：SpringBoard（系统级），不对游戏进程做任何注入，降低封号风险。
 * 触摸通过 SpringBoard 的 BackBoardServices / IOHIDEventSystemClient
 * 全局派发到当前前台 App（游戏）。
 *
 * DeltaHarmonica (com.hanzemo.deltaharmonica)
 * ===================================================================== */

/* ---------- 口琴键盘布局（12 键，与安卓 DF-NoctReed 一致） ----------
 * 8 个音符键：1 2 3 4 5 6 7 i（do re mi fa sol la si + 高音 do）
 * 4 个调性/音区切换键：低音区(FLAT)、中音区(NATURAL)、高音区(SHARP)、半音(HALF)
 */

typedef NS_ENUM(NSInteger, DFHRegister) {
    DFHRegisterFlat = 0,     /* 低音区 */
    DFHRegisterNatural = 1,  /* 中音区 */
    DFHRegisterSharp = 2,    /* 高音区 */
};

/* ---------- 标定键编号（13 键，存偏好 coord.0 ~ coord.12） ---------- */
#define DFH_KEY_DO      0
#define DFH_KEY_RE      1
#define DFH_KEY_MI      2
#define DFH_KEY_FA      3
#define DFH_KEY_SOL     4
#define DFH_KEY_LA      5
#define DFH_KEY_SI      6
#define DFH_KEY_DO_HIGH 7   /* 高音 do（i） */
#define DFH_KEY_FLAT    8   /* 低音区切换 */
#define DFH_KEY_NATURAL 9   /* 中音区切换 */
#define DFH_KEY_SHARP   10  /* 高音区切换 */
#define DFH_KEY_HALF    11  /* 半音键 */
#define DFH_KEY_EXTRA   12  /* 保留 */

#define DFH_TOTAL_KEYS 13

/* ---------- MIDI 常量 ---------- */
#define DFH_MIDI_MIN 60   /* C4 */
#define DFH_MIDI_MAX 96   /* C7 */
#define DFH_DEFAULT_BPM 120.0

/* ---------- 时序精度（与安卓对齐） ---------- */
#define DFH_TICKS_PER_BEAT 16
#define DFH_MIN_HOLD_MS 30.0
#define DFH_MAX_HOLD_MS 60.0

/* =====================================================================
 * 对外 API（DFHCore.m 实现）
 * ===================================================================== */

/* 标定坐标存取 */
BOOL   DFHStoreCoord(NSInteger keyIdx, CGPoint p);
CGPoint DFHLoadCoord(NSInteger keyIdx, BOOL *valid);

/* 触摸注入：点击某编号键（内部读标定坐标），holdMs 为按住时长 */
void DFHTapKey(NSInteger keyIdx, double holdMs);

/* 触摸注入：点击某逻辑坐标 */
void DFHTapAtPoint(CGPoint point, double holdMs);

NS_ASSUME_NONNULL_END
