#import "DFHMIDIParser.h"

/* =====================================================================
 * DFHMIDIParser.m
 * 标准 MIDI 文件 (SMF) 解析实现
 *
 * 支持：
 *  - SMF header "MThd" + track chunk "MTrk"
 *  - 变长 (VLQ) 读取
 *  - Running Status
 *  - note on/off (0x9n / 0x8n)，note on vel=0 视为 off
 *  - Tempo meta (0xFF 0x51 03 tttttt) -> 每拍微秒 -> BPM
 *  - End of Track (0xFF 0x2F)
 *
 * 音高级别映射（复刻 DF-NoctReed 的口琴键位表）：
 *  三角洲口琴可演奏音域 C4(MIDI 60) ~ C7(MIDI 96)。
 *  每个音高 => (音区 register, 音名 degree, 是否半音 accidental)
 * ===================================================================== */

@implementation DFHNoteEvent
@end

@implementation DFHMIDIResult
@end

/* ---------- 音区 + 音名 + 半音 映射 ---------- */

/* C 大调自然音阶（不含半音）：C D E F G A B
 * 三角洲口琴是 C 调口琴，自然音对应白键，半音需要"半音键"。
 * 这里把 MIDI pitch (60..96) 映射到口琴的（音区 + 自然音名 + 半音标志）。 */

static DFHPitchMap DFHMapPitch(uint8_t pitch) {
    DFHPitchMap m = { DFHRegisterNatural, 1, NO };

    /* C 大调自然音在白键上的半音偏移：C D E F G A B */
    static const int natural[] = { 0, 2, 4, 5, 7, 9, 11 };

    if (pitch < DFH_MIDI_MIN || pitch > DFH_MIDI_MAX) {
        uint8_t clamped = pitch < DFH_MIDI_MIN ? DFH_MIDI_MIN : DFH_MIDI_MAX;
        return DFHMapPitch(clamped);
    }

    int rel = pitch - DFH_MIDI_MIN;          /* 0..36 相对 C4 */
    int semitone = rel % 12;                 /* 0..11 相对 C */

    /* 特殊：C6（高音 do），用独立物理键（编号 7，degree=8），
     * 不需要切高音区。C7(96) 超出常规，也走独立键兜底。 */
    if (pitch == 84) {
        m.reg = DFHRegisterSharp;
        m.degree = 8;          /* 高音 do 独立键 */
        m.accidental = NO;
        return m;
    }

    /* 统一"升半音"语义：黑键映射为"前一个自然音 + 半音键"。
     * 例：C#(1)→do+半音，D#(3)→re+半音，F#(6)→fa+半音，
     *     G#(8)→sol+半音，A#(10)→la+半音。 */
    int degree = 1;        /* 1..7 */
    BOOL accidental = NO;

    for (int i = 0; i < 7; i++) {
        if (semitone == natural[i]) { degree = i + 1; accidental = NO; break; }
        /* 黑键：位于 natural[i] 与 natural[i+1] 之间（差 2 半音的那个空档） */
        if (i < 6 && semitone == natural[i] + 1) { degree = i + 1; accidental = YES; break; }
    }

    /* 音区：按 pitch 所在八度映射（与 DF-NoctReed 一致） */
    if (pitch >= 60 && pitch <= 71)       m.reg = DFHRegisterFlat;
    else if (pitch >= 72 && pitch <= 83)  m.reg = DFHRegisterNatural;
    else                                  m.reg = DFHRegisterSharp;

    m.degree = degree;
    m.accidental = accidental;
    return m;
}

/* ---------- VLQ / 字节读取 ---------- */

typedef struct {
    const uint8_t *data;
    NSUInteger     len;
    NSUInteger     pos;
    BOOL           err;
} DFHReader;

static void DFHRdInit(DFHReader *r, NSData *d) {
    r->data = d.bytes;
    r->len  = d.length;
    r->pos  = 0;
    r->err  = NO;
}

static uint8_t DFHRdByte(DFHReader *r) {
    if (r->pos >= r->len) { r->err = YES; return 0; }
    return r->data[r->pos++];
}

static uint32_t DFHRdU32(DFHReader *r) {
    uint32_t v = 0;
    v |= ((uint32_t)DFHRdByte(r)) << 24;
    v |= ((uint32_t)DFHRdByte(r)) << 16;
    v |= ((uint32_t)DFHRdByte(r)) << 8;
    v |= ((uint32_t)DFHRdByte(r));
    return v;
}

static uint16_t DFHRdU16(DFHReader *r) {
    uint16_t v = 0;
    v |= ((uint16_t)DFHRdByte(r)) << 8;
    v |= ((uint16_t)DFHRdByte(r));
    return v;
}

/* 可变长度数量 VLQ */
static uint64_t DFHRdVLQ(DFHReader *r) {
    uint64_t v = 0;
    for (int i = 0; i < 4; i++) {
        uint8_t b = DFHRdByte(r);
        v = (v << 7) | (b & 0x7F);
        if (!(b & 0x80)) return v;
    }
    r->err = YES;
    return v;
}

static void DFHRdSkip(DFHReader *r, NSUInteger n) {
    r->pos += n;
    if (r->pos > r->len) { r->pos = r->len; r->err = YES; }
}

/* ---------- 解析实现 ---------- */

@implementation DFHMIDIParser

+ (DFHMIDIResult *)parseFileAtPath:(NSString *)path error:(NSError **)error {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) {
        if (error) *error = [NSError errorWithDomain:@"DFHMIDI"
                                               code:1
                                           userInfo:@{NSLocalizedDescriptionKey:@"无法读取 MIDI 文件"}];
        return nil;
    }
    return [self parseData:d error:error];
}

+ (DFHMIDIResult *)parseData:(NSData *)d error:(NSError **)error {
    DFHReader r;
    DFHRdInit(&r, d);

    /* --- header MThd --- */
    char hdr[4];
    for (int i = 0; i < 4; i++) hdr[i] = (char)DFHRdByte(&r);
    if (memcmp(hdr, "MThd", 4) != 0) {
        if (error) *error = [NSError errorWithDomain:@"DFHMIDI" code:2
                                     userInfo:@{NSLocalizedDescriptionKey:@"非标准 MIDI 文件（缺少 MThd）"}];
        return nil;
    }
    uint32_t hdrLen = DFHRdU32(&r);
    uint16_t format = DFHRdU16(&r);
    uint16_t ntracks = DFHRdU16(&r);
    uint16_t division = DFHRdU16(&r);
    DFHRdSkip(&r, hdrLen - 6); /* 已知剩余的 header 数据 */

    /* division：ticks per quarter note（这里假定非 SMPTE，绝大多数情况） */
    uint32_t ticksPerQuarter = division & 0x7FFF;
    if (ticksPerQuarter == 0) ticksPerQuarter = 480;

    /* 每拍微秒，默认 500000（120 BPM）；后续由 Tempo meta 覆盖 */
    double usPerQuarter = 500000.0;
    double bpm = DFH_DEFAULT_BPM;

    NSMutableArray<DFHNoteEvent *> *notes = [NSMutableArray array];

    for (uint16_t t = 0; t < ntracks && !r.err; t++) {
        char th[4];
        for (int i = 0; i < 4; i++) th[i] = (char)DFHRdByte(&r);
        if (memcmp(th, "MTrk", 4) != 0) {
            /* 容忍非标准 chunk：跳过 */
            void *lenp = NULL; (void)lenp;
            uint32_t skipLen = DFHRdU32(&r);
            DFHRdSkip(&r, skipLen);
            continue;
        }
        uint32_t trkLen = DFHRdU32(&r);
        NSUInteger trkEnd = r.pos + trkLen;

        uint64_t tick = 0;
        uint8_t  running = 0;

        /* 记录 in-flight note on，用于匹配 off 计算时长 */
        NSMutableDictionary<NSNumber *, NSMutableArray<DFHNoteEvent *> *> *pending =
            [NSMutableDictionary dictionary];

        while (r.pos < trkEnd && !r.err) {
            uint64_t dt = DFHRdVLQ(&r);
            tick += dt;

            uint8_t ev = DFHRdByte(&r);
            if (ev & 0x80) { running = ev; }
            else { r.pos--; ev = running; }  /* running status */

            uint8_t status = ev & 0xF0;
            uint8_t chan   = ev & 0x0F;

            if (status == 0x80 || status == 0x90) { /* note off / note on */
                uint8_t pitch = DFHRdByte(&r);
                uint8_t vel   = DFHRdByte(&r);

                uint64_t absUs = (uint64_t)((double)tick * usPerQuarter / (double)ticksPerQuarter);

                if (status == 0x90 && vel > 0) {
                    DFHNoteEvent *n = [DFHNoteEvent new];
                    n.pitch = pitch;
                    n.startUs = absUs;
                    n.channel = chan;
                    n.velocity = vel;
                    [notes addObject:n];

                    NSNumber *key = @(pitch);
                    NSMutableArray *arr = pending[key];
                    if (!arr) { arr = [NSMutableArray array]; pending[key] = arr; }
                    [arr addObject:n];
                } else {
                    /* note off */
                    NSNumber *key = @(pitch);
                    NSMutableArray<DFHNoteEvent *> *arr = pending[key];
                    if (arr.count > 0) {
                        DFHNoteEvent *n = arr.firstObject;
                        n.durationUs = absUs - n.startUs;
                        [arr removeObjectAtIndex:0];
                    }
                }
            } else if (status == 0xA0) { /* poly aftertouch，跳过2字节 */
                DFHRdByte(&r); DFHRdByte(&r);
            } else if (status == 0xB0) { /* control change */
                DFHRdByte(&r); DFHRdByte(&r);
            } else if (status == 0xC0 || status == 0xD0) { /* program/channel aftertouch */
                DFHRdByte(&r);
            } else if (status == 0xE0) { /* pitch bend */
                DFHRdByte(&r); DFHRdByte(&r);
            } else if (ev == 0xFF) { /* meta */
                uint8_t type = DFHRdByte(&r);
                uint64_t len = DFHRdVLQ(&r);
                if (type == 0x51 && len == 3) { /* tempo, 微秒每四分音符 */
                    uint8_t b1 = DFHRdByte(&r), b2 = DFHRdByte(&r), b3 = DFHRdByte(&r);
                    usPerQuarter = ((uint32_t)b1 << 16) | ((uint32_t)b2 << 8) | b3;
                    bpm = 60000000.0 / usPerQuarter;
                } else if (type == 0x2F) { /* end of track */
                    DFHRdSkip(&r, (NSUInteger)len);
                    break;
                } else {
                    DFHRdSkip(&r, (NSUInteger)len);
                }
            } else if (ev == 0xF0 || ev == 0xF7) { /* sysex */
                uint64_t len = DFHRdVLQ(&r);
                DFHRdSkip(&r, (NSUInteger)len);
            } else {
                r.err = YES;
                break;
            }
        }
        r.pos = trkEnd; /* 对齐到 track 结束 */
    }

    /* 收尾：未匹配到 note off 的，给个默认短时长 */
    for (DFHNoteEvent *n in notes) {
        if (n.durationUs == 0) n.durationUs = (uint64_t)(usPerQuarter / 4.0);
    }

    /* 排序（按轨道里已有序，但保险起见按 startUs） */
    [notes sortUsingComparator:^NSComparisonResult(DFHNoteEvent *a, DFHNoteEvent *b) {
        if (a.startUs < b.startUs) return NSOrderedAscending;
        if (a.startUs > b.startUs) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    uint64_t total = 0;
    for (DFHNoteEvent *n in notes) {
        uint64_t end = n.startUs + n.durationUs;
        if (end > total) total = end;
    }

    DFHMIDIResult *res = [DFHMIDIResult new];
    res.notes = notes;
    res.bpm = bpm;
    res.totalDurationUs = total;
    res.format = format;
    res.trackCount = ntracks;
    return res;
}

#pragma mark - 音高映射对外接口（供 DFHPlayer 使用）

@implementation DFHMIDIParser (PitchMapping)

+ (DFHPitchMap)pitchMapFor:(uint8_t)pitch {
    return DFHMapPitch(pitch);
}

@end
