```markdown
# DeltaHarmonica — 三角洲行动·守夜人口琴 自动演奏插件

一个 iOS 越狱 tweak，让《三角洲行动》里的守夜人口琴根据 **MIDI 文件自动吹奏**。

参考安卓端 [DF-NoctReed](https://github.com/JeanWenzelCN/DF-NoctReed)（Kotlin）与
PC 端 [delta-harmonica](https://gitcode.com/wolaizhaowo/delta-harmonica)（Python）的原理，
在 iOS 上复刻「音区切换 + 音名按押」的演奏机制。

> ⚠️ 免责声明：本项目仅供学习越狱插件开发与自动化注入技术。请勿用于破坏游戏公平性、
> 违反游戏用户协议或任何违规用途，由此产生的一切后果由使用者自行承担。

---

## 核心设计：仅注入 SpringBoard（防封号）

本插件**不对《三角洲行动》进程做任何代码注入**，只注入 **SpringBoard**（系统级进程）：

1. **注入目标**：`com.apple.springboard`
2. **触摸注入**：SpringBoard 拥有系统级权限，通过 IOKit 的
   `IOHIDEventSystemClient` 全局派发 digitizer 触摸事件，投递到**当前前台 App（游戏）**。
3. **控制界面**：在 SpringBoard 内创建一个系统级悬浮窗（UIWindow），提供完整控制面板。

> 这是与安卓版 DF-NoctReed「注入游戏 + 无障碍手势」的本质区别：iOS 上把注入点移到
> 系统层的 SpringBoard，从源头避免对游戏二进制的 hook，可显著降低被反作弊检测概率。

### 已查证的真实 Bundle ID（供参考 / 前台识别）

| 版本 | 发行方 | Bundle ID | App Store |
| --- | --- | --- | --- |
| 国服 | 深圳腾讯天游 | `com.tencent.tmgp.dfm` | [id1642894547](https://apps.apple.com/cn/app/id1642894547) |
| 国际服 | Garena | `com.garena.game.df` | [id6670604287](https://apps.apple.com/tw/app/id6670604287) |

### 前台校验（已实现，防封号核心）

插件内置**前台 App 白名单护栏**（`DFHForeground.m`）：

- 每次派发触摸前，通过 SpringBoard 私有 API（`SBApplicationController` /
  `UIApplication frontmostApplication`）读取**当前前台 App 的 bundle id**
- **仅当精确匹配 `com.tencent.tmgp.dfm` 或 `com.garena.game.df` 时才放行**触摸注入
- 否则直接拦截，日志输出 `[DFH] 前台非三角洲...已拦截`，杜绝误触/误注入其他 App

> 这意味着：即使误触发播放、误按手势，只要当前不在三角洲（精确匹配），就不会向任何 App
> 注入触摸，从根本上降低被检测/误操作的风险。

---

## 一、原理

《三角洲行动》是 Unity 引擎游戏，触摸走 `IOHIDEvent`。插件在 SpringBoard 内构造
digitizer 事件并全局派发到前台 App。演奏时把 MIDI 音符序列按时间轴翻译成三类动作：

| 动作 | 说明 |
| --- | --- |
| 调性切换键 | 低音区 / 中音区 / 高音区，跨音区先切换（120ms 间隙） |
| 半音键 | 有升降号的音符，先按半音键（80ms 间隙）再按音符 |
| 音符键 | `do·re·mi·fa·sol·la·si·do⁺`（8 键），按押 `holdMs` 实现延音/连音 |

时序与安卓版对齐：**1 拍 = 16 tick**，`节拍ms = 60000/BPM`，按押 `holdMs = noteMs-30ms`
（30~60ms 夹取）。高 BPM 下十六分音符连音/漏音是平台调度精度固有限制。

### BPM 归一化

播放时把 `bpm` 归一化到 120：`tempoScale = bpm / 120.0`，所有音符的
`startUs/durationUs/totalDurationUs` 都除以 `tempoScale`，统一到「1 拍 = 500000us」的
尺度。**不改 `DFHMIDIParser` 的输出**，只在 `DFHPlayer` 内部做副本缩放，进度条、
`seekToUs:`、`lastPlayedUs` 全部用归一化后的尺度。

### 倍速

`DFHPlayer.rate` 范围 0.5–3.0，默认 1.0。倍速只影响**实际等待时间**
（`targetUs / rate`），不改变归一化时间轴尺度。播放中改变倍速会从当前位置重建
时间基准，不停播。

---

## 二、目录结构

```

DeltaHarmonica/
├── control                 # Debian 包元信息
├── Makefile                # Theos 编译（roothide scheme，tweak + 命令行工具）
├── entitlements.plist      # roothide entitlements
├── Tweak.xm                # 注入 SpringBoard + 悬浮控制台 + 前后台监听
├── DFHCore.h/.m            # IOHID 触摸注入 + 键位标定
├── DFHForeground.h/.m      # 前台 App 校验（防封号护栏）
├── DFHMIDIParser.h/.m      # 标准 MIDI 解析 + 音高→键位映射
├── DFHPlayer.h/.m          # 演奏调度器（时间轴派发、BPM 归一化、倍速、seek、进度保存）
├── dfhctl.m                # 命令行触发工具
├── .github/workflows/      # GitHub Actions CI（roothide fork 编译）
├── layout/
│   └── Library/PreferenceBundles/DeltaHarmonicaPrefs.bundle/
└── README.md

```

---

## 三、编译（roothide）

> 必须在 **macOS + Theos** 编译（iOS tweak 无法在 Linux 交叉编译）。

**roothide 专用要点**（依据 roothide/Developer 官方规范）：

1. 使用 **roothide/theos fork**（与官方 theos 100% 兼容，内置 roothide 支持）
2. `THEOS_PACKAGE_SCHEME=roothide`（**非**标准 rootless）
3. 源码访问越狱文件用 `jbroot()` API，**不硬编码 `/var/jb`**

```bash
# 1. 安装 roothide/theos
bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)"

# 2. 放入 SDK（iPhoneOS16.5.sdk 到 ~/theos/sdks/，含私有框架 tbd）
#    或直接克隆：git clone https://github.com/theos/sdks 并复制 iPhoneOS16.5.sdk

# 3. 编译
cd DeltaHarmonica
make clean
make package          # 生成 .deb（含 tweak + dfhctl，roothide scheme）
make install          # 需配置 THEOS_DEVICE_IP/PORT
```

产物 packages/com.hanzemo.deltaharmonica_1.0.0_iphoneos-arm64.deb，
Sileo/Zebra 安装或 dpkg -i。

也可用 GitHub Actions 自动编译：推送后 .github/workflows/build.yml 自动产出 .deb。

---

四、使用步骤

1. 启用

Sileo 勾选 DeltaHarmonica，注入目标是 SpringBoard；安装后 respring。

2. 打开控制台

· 三角洲前台按音量下键 → 显示/隐藏控制面板（非三角洲前台音量键正常调音量）
· 面板「收起」按钮 → 只隐藏，播放继续
· 30 秒无操作自动隐藏（播放继续）
· 顶部标题栏左侧区域可拖动窗口，右侧「⤢」循环小/中/大三档尺寸

3. 标定 12 键

1. 进入游戏 → 守夜人弹口琴界面（12 键完整显示），手机横屏
2. 控制台点「🎯 标定」
3. 按提示依次点击：do re mi fa sol la si 高音do、低音区、中音区(普通)、高音区、半音
4. 标定时面板自动隐藏，全屏半透明遮罩接管一次点击；点完自动恢复面板
5. 坐标存入偏好 coord.0~coord.11

标定坐标是横屏 pt，播放时乘 scale 转物理像素注入。如果标定时竖屏，坐标会超范围，
触摸打到屏幕外。

4. 导入 MIDI

· 点控制台「📂 导入」→ 系统文件选择器（UTTypeMIDI）→ 选 .mid/.midi 文件
· 自动拷贝到 DFHMidiDirectory()（jbroot(@"/var/mobile/Documents/DeltaHarmonica")），
  重名自动加 -1 后缀
· 也可用 Filza 手动放入该目录，面板 viewWillAppear 或三角洲回到前台时自动 refreshList

5. 演奏控制

按钮 功能
▶ 播放 播放列表中选中的乐谱（点列表项直接播放）
⏹ 停止 停止并保存进度到 lastPlayedUs
🔁 重播 从头重播 lastMidi
📂 导入 系统文件选择器导入 MIDI
🎯 标定 进入 12 键标定流程

面板底部还有：

· 进度条：范围 0–1，映射到归一化总时长；播放中 onProgress 更新，用户拖动时
  isTracking 忽略自动更新，松手调 seekToUs: 跳转
· 倍速按钮：0.5 → 1.0 → 1.5 → 2.0 → 2.5 → 3.0 → 0.5 循环，按钮文字显示当前倍速

6. 命令行工具 dfhctl

```bash
# roothide 下 dfhctl 安装在 jbroot 内，路径由包管理器决定
dfhctl play song.mid   # 播放
dfhctl stop            # 停止
dfhctl replay          # 重播
dfhctl panel           # 弹出控制台
```

也可绑定 Activator 手势 → 运行命令，实现游戏内快捷键。

Activator 的「运行命令」中，dfhctl 安装在 jbroot 内（roothide 下路径随机），
建议直接填 dfhctl ... 让其通过 PATH 解析，或用 which dfhctl 查实际绝对路径。
配合前台精确匹配校验：即使误触手势，前台非三角洲时也不会注入任何触摸。

7. 进度恢复

· 退后台 / 停止 / 退出三角洲：pauseAndSave 把当前归一化位置写入
  lastPlayedUs，lastMidi 保留
· 自然播完：lastPlayedUs 置 0，lastMidi 保留
· 下次进入三角洲前台（UIApplicationDidBecomeActiveNotification + 前台是三角洲 +
  lastMidi 存在 + lastPlayedUs > 0）：弹 UIAlertController
  「上次播放到 xx:xx，是否继续？」，按钮「继续 / 从头 / 取消」
  · 继续：playResult:fromUs:lastPlayedUs
  · 从头：playResult:fromUs:0，清 lastPlayedUs
  · 取消：不播

弹窗挂在临时 UIWindow（windowLevel = Alert + 2000），避免 SpringBoard 里
presentViewController: 因“view is not in the window hierarchy”失败。

---

五、音域与键位映射

三角洲口琴 C 调，12 键 = 8 个音符键 + 4 个切换键：

类型 键 说明
音符键（8） do re mi fa sol la si + 高音do 固定物理键
切换键（4） 低音区 / 中音区(普通) / 高音区 / 半音 切换式，按一下切模式

演奏逻辑（与实机一致）：

· 音符键固定：do re mi fa sol la si 永远是这 7 个键，音高由切换键决定
· 音区切换：低音区(C4–B4) / 中音区(C5–B5) / 高音区(C6–C7)，跨音区才切一次
· 半音切换：也是切换式，进/出半音模式才按一次（升半音语义）
· 高音 do 独立键：吹 C6 直接按高音 do 键（编号 7），不需先切高音区
· 超界削波

音高映射表（C4=60 ~ C7=96，38 键）

音区 音高 MIDI 切换键
低音区 C4–B4 60–71 低音区
中音区 C5–B5 72–83 中音区(普通)
高音区 C6–C7 84–96 高音区（C6 用高音do独立键）

MIDI 建议单旋律轨、C 大调、音域 C4–C7。

---

五·五、Activator 手势绑定

安装 Activator 后，可把演奏控制绑定到手势（如摇一摇、双击状态栏等），
实现游戏内无悬浮窗操作：

1. 打开 Activator → 「任意位置」→ 选一个手势（如「双击状态栏」）
2. 搜索并绑定以下「运行命令」：

手势建议 命令
摇一摇 dfhctl replay
双击状态栏 dfhctl panel
三指轻点 dfhctl stop

Activator 的「运行命令」中，dfhctl 安装在 jbroot 内（roothide 下路径随机），
建议直接填 dfhctl ... 让其通过 PATH 解析，或用 which dfhctl 查实际绝对路径。
也可在 Activator 里直接给 dfhctl 配 play <文件名> 固定手势。

配合前台精确匹配校验：即使误触手势，前台非三角洲时也不会注入任何触摸，安全无副作用。

---

六、排错

1. IOHIDEventCreateDigitizerEvent 签名不匹配 / 触摸静默失败：
   iOS 14/15/16 上该函数是 15 参（x/y/z/pressure/twist 为 IOHIDFloat，
   最后 boolean_t range, touch, IOOptionBits options）。14 参 extern 会导致调用栈
   错位、事件创建失败。当前 DFHCore.m 用 dlopen + dlsym 运行时查找，优先
   IOHIDEventCreateDigitizerFingerEvent（13 参，更稳），回退 15 参
   IOHIDEventCreateDigitizerEvent。若日志出现 符号未找到，检查 IOKit 路径
   （/System/Library/Frameworks/IOKit.framework/IOKit）。
2. 游戏收不到触摸：
   · 确认 DeltaHarmonica 注入 SpringBoard 成功（Sileo 勾选 + respring）
   · 看 dfh.log 里 SendTouch ok phase=1/4 是否出现；有日志但游戏没反应，检查
     DFHShouldInject 是否返回 NO（日志 前台非三角洲...拦截）
   · 确认标定坐标是横屏 pt，TapKey 日志里 y 应 ≤ 屏幕横屏高度
   · 合成 HID 事件需要合法 SenderID（IOHIDEventSetSenderID(ev, 0x8000000817319372ULL)），
     否则系统静默丢弃
3. 十六分音符连音/漏音：平台精度固有限制，降 BPM 或放宽音值可缓解。
4. 悬浮窗不出现：
   · 非三角洲前台音量键不弹面板（设计如此，白名单放行音量）
   · 三角洲前台按音量下，看日志 音量下事件命中[SBVolumeControl decreaseVolume]
   · 面板 windowScene 选到 SystemAperture 会导致不显示，DFHShowPanel 里已跳过
5. 进度条停止后还动：DFHPlayer.m 的 updateCurrentUs:token: 里应有
   if (!_playing) return;，停止后不再推进度条。
6. 导入失败：documentPicker:didPickDocumentsAtURLs: 用 NSData 读 + writeToFile:
   写，避免 copyItemAtURL: 对安全作用域 URL 的路径检查失败；asCopy:NO 拿原文件
   安全作用域 URL，startAccessingSecurityScopedResource 后读。

---

七、License

GPL-3.0（与 DF-NoctReed 一致）

---

八、公告

本插件由大肥鱼（dsh）编写，测试阶段不代表最终质量

```