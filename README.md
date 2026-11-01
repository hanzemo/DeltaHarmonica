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
3. **控制界面**：在 SpringBoard 内创建一个系统级悬浮窗（UIWindow），提供完整设置面板。

> 这是与安卓版 DF-NoctReed「注入游戏 + 无障碍手势」的本质区别：iOS 上把注入点移到
> 系统层的 SpringBoard，从源头避免对游戏二进制的 hook，可显著降低被反作弊检测概率。

### 已查证的真实 Bundle ID（供参考 / 前台识别）

| 版本 | 发行方 | Bundle ID | App Store |
| --- | --- | --- | --- |
| 国服 | 深圳腾讯天游 | `com.tencent.tmgp.dfm` | [id1642894547](https://apps.apple.com/cn/app/id1642894547) |
| 国际服 | Garena | `com.garena.game.df` | [id6670604287](https://apps.apple.com/tw/app/id6670604287) |

### 白名单校验（已实现，防封号核心）

插件内置**前台 App 白名单护栏**（`DFHForeground.m`）：

- 每次派发触摸前，通过 SpringBoard 私有 API（`SBApplicationController` /
  `UIApplication frontmostApplication`）读取**当前前台 App 的 bundle id**
- **仅当前台是《三角洲行动》（国服/国际服）时才放行**触摸注入
- 否则直接拦截，日志输出 `[DFH] 前台非三角洲...已拦截`，杜绝误触/误注入其他 App
- 默认开启，可在悬浮窗「🛡 白名单」按钮或偏好 `whiteListEnabled` 关闭

> 这意味着：即使误触发播放、误按手势，只要当前不在游戏里，就不会向任何 App 注入触摸，
> 从根本上降低被检测/误操作的风险。

---

## 一、原理

《三角洲行动》是 Unity 引擎游戏，触摸走 `IOHIDEvent`。插件在 SpringBoard 内构造
digitizer 事件并全局派发到前台 App。演奏时把 MIDI 音符序列按时间轴翻译成三类动作：

| 动作 | 说明 |
| --- | --- |
| 调性切换键 | 低音区 / 中音区 / 高音区，跨音区先切换（120ms 间隙） |
| 半音键 | 有升降号的音符，先按半音键（60ms 间隙）再按音符 |
| 音符键 | `do·re·mi·fa·sol·la·si·do⁺`（8 键），按押 `holdMs` 实现延音/连音 |

时序与安卓版对齐：**1 拍 = 16 tick**，`节拍ms = 60000/BPM`，按押 `holdMs = noteMs-30ms`
（30~60ms 夹取）。高 BPM 下十六分音符连音/漏音是平台调度精度固有限制。

---

## 二、目录结构

```
DeltaHarmonica/
├── control                 # Debian 包元信息
├── Makefile                # Theos 编译（tweak + 命令行工具）
├── Tweak.xm                # 注入 SpringBoard + 悬浮窗设置界面 + 通知监听
├── DFHCore.h/.m            # IOHID 触摸注入（全局派发）+ 键位标定
├── DFHMIDIParser.h/.m      # 标准 MIDI 解析 + 音高→键位映射
├── DFHPlayer.h/.m          # 演奏调度器（时间轴派发）
├── dfhctl.m                # 命令行触发工具（-> /usr/bin/dfhctl）
├── layout/
│   └── Library/PreferenceBundles/DeltaHarmonicaPrefs.bundle/
└── README.md
```

---

## 三、编译

> 必须在 **macOS + Theos** 编译（iOS tweak 无法在 Linux 交叉编译）。

```bash
git clone --recursive https://github.com/theos/theos.git ~/theos
# 放入 iPhoneOS16.0.sdk 到 ~/theos/sdks/
cd DeltaHarmonica
make clean
make package          # 生成 .deb（含 tweak + dfhctl）
make install          # 需配置 THEOS_DEVICE_IP/PORT
```

产物 `packages/com.hanzemo.deltaharmonica_1.0.0_iphoneos-arm64.deb`，
Sileo/Zebra 安装或 `dpkg -i`。

---

## 四、使用步骤

### 1. 启用
Sileo 勾选 DeltaHarmonica，注入目标是 SpringBoard；安装后 respring。

### 2. 打开控制台
- 安装后 SpringBoard 内自动弹出一次悬浮窗
- 命令行 `dfhctl panel` 可再次呼出
- 悬浮窗可「收起」到边缘，随时点开

### 3. 标定 13 键
1. 进入游戏 → 守夜人弹口琴界面（12 键完整显示）
2. 控制台点「🎯 标定」
3. 按提示依次点击：`do re mi fa sol la si do⁺`、低音区、中音区、高音区、半音
4. 坐标存入偏好 `coord.0`~`coord.11`

### 4. 导入 MIDI
- 点控制台「📂 导入」刷新列表
- 用 Filza 把 `.mid` 放入 `Documents/DeltaHarmonica/`（roothide 下 `/var/jb/var/mobile/Documents/DeltaHarmonica`）
- 列表即显示，点选后按「▶ 播放」

### 5. 演奏控制
| 按钮 | 功能 |
| --- | --- |
| ▶ 播放 | 播放选中乐谱 |
| ⏹ 停止 | 停止 |
| 🔁 重播 | 重播上一首 |
| 📂 导入 | 刷新 MIDI 列表 |
| 🎯 标定 | 进入标定流程 |

### 6. 命令行工具 `dfhctl`

```bash
/var/jb/usr/bin/dfhctl play song.mid   # 播放
/var/jb/usr/bin/dfhctl stop            # 停止
/var/jb/usr/bin/dfhctl replay          # 重播
/var/jb/usr/bin/dfhctl panel           # 弹出控制台
/var/jb/usr/bin/dfhctl list            # 列出乐谱
```

也可绑定 Activator 手势 → 运行命令，实现游戏内快捷键。

---

## 五、音域与键位映射

三角洲口琴 C 调，**12 键 = 8 个音符键 + 4 个切换键**：

| 类型 | 键 | 说明 |
| --- | --- | --- |
| 音符键（8） | `do re mi fa sol la si` + 高音`do` | 固定物理键 |
| 切换键（4） | 低音区 / 中音区(普通) / 高音区 / 半音 | **切换式**，按一下切模式 |

演奏逻辑（与实机一致）：

- **音符键固定**：`do re mi fa sol la si` 永远是这 7 个键，音高由切换键决定
- **音区切换**：低音区(C4–B4) / 中音区(C5–B5) / 高音区(C6–C7)，跨音区才切一次
- **半音切换**：也是切换式，进/出半音模式才按一次（升半音语义）
- **高音 do 独立键**：吹 C6 直接按高音 do 键（编号 7），不需先切高音区
- 超界削波

### 音高映射表（C4=60 ~ C7=96，38 键）

| 音区 | 音高 | MIDI | 切换键 |
| --- | --- | --- | --- |
| 低音区 | C4–B4 | 60–71 | 低音区 |
| 中音区 | C5–B5 | 72–83 | 中音区(普通) |
| 高音区 | C6–C7 | 84–96 | 高音区（C6 用高音do独立键） |

MIDI 建议单旋律轨、C 大调、音域 C4–C7。

---

## 五·五、Activator 手势绑定

安装 [Activator](http://rpetri.ch/cydia/activator/) 后，可把演奏控制绑定到手势（如摇一摇、双击状态栏等），
实现游戏内无悬浮窗操作：

1. 打开 Activator → 「任意位置」→ 选一个手势（如「双击状态栏」）
2. 搜索并绑定以下「运行命令」：

| 手势建议 | 命令 |
| --- | --- |
| 摇一摇 | `/var/jb/usr/bin/dfhctl replay` |
| 双击状态栏 | `/var/jb/usr/bin/dfhctl panel` |
| 三指轻点 | `/var/jb/usr/bin/dfhctl stop` |

> Activator 的「运行命令」需以 root（或 jb 用户）身份执行 dfhctl，
> 命令路径 rootless 下为 `/var/jb/usr/bin/dfhctl`。
> 也可在 Activator 里直接给 dfhctl 配 `play <文件名>` 固定手势。

配合**白名单校验**：即使误触手势，前台非三角洲时也不会注入任何触摸，安全无副作用。

---

## 六、排错

1. **`IOHIDEventCreateDigitizerEvent` 链接报错**：签名因 iOS 版本而异，用 `nm` 查设备 IOKit 真实符号，调整 `DFHCore.m` 的 extern 声明。
2. **游戏收不到触摸**：确认 DeltaHarmonica 注入 SpringBoard 成功（Sileo 勾选 + respring）；确认标定坐标正确。
3. **十六分音符连音/漏音**：平台精度固有限制，降 BPM 或放宽音值可缓解。
4. **悬浮窗不出现**：`killall -9 SpringBoard` 后重试，或 `dfhctl panel`。

---

## 七、License

GPL-3.0（与 DF-NoctReed 一致）
