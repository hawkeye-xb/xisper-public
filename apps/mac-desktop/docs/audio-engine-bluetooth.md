# AudioEngine 蓝牙兼容性：从 AVAudioEngine 到 CoreAudio AUHAL

> 2026-03-24 排查记录。经历 7 轮修复，最终弃用 AVAudioEngine，改用 CoreAudio AUHAL。

## 问题

用户戴蓝牙耳机使用 Xisper 录音时：
- app 崩溃（EXC_BAD_ACCESS NULL 指针，SwiftUI 按钮点击时）
- 录音启动但 ASR 收到零数据
- 开始录音的音效不播放/破声/延迟到录音结束才播放

## 根因

**AVAudioEngine 在 macOS 上无法可靠处理蓝牙音频设备。** 这是 Apple 框架层的已知缺陷。

### AVAudioEngine 的 5 个具体问题

| # | 问题 | 后果 |
|---|---|---|
| 1 | `inputNode.outputFormat(forBus: 0)` 返回**缓存值** | BT 从 A2DP (48kHz) 切到 HFP (24kHz) 后仍返回 48kHz |
| 2 | `installTap(format: nil)` 在 macOS 上使用缓存格式 | 不是"用硬件真实格式"，是"用 node 当前格式"（缓存的） |
| 3 | 内部图协商在 BT 编解码器切换时失败 | 报错 `-10868 kAudioUnitErr_FormatNotSupported` |
| 4 | `AVAudioEngineConfigurationChange` 通知在 warmup 期间也触发 | 导致无限重建循环 |
| 5 | 没有 `AVAudioSession`（iOS 有，macOS 没有） | 无法声明"我只用输入不用输出"，BT 编解码器切换不可控 |

### 蓝牙编解码器切换机制

蓝牙耳机有两个模式：
- **A2DP**：高品质音频输出（48kHz 立体声）— 听音乐
- **HFP**：低品质双向通话（16/24kHz 单声道）— 麦克风 + 听筒

激活麦克风 → macOS 自动从 A2DP 切到 HFP。这个切换需要 200-500ms，期间音频输入输出管道都不稳定。

## 尝试过的方案

### 方案 1：监听 ConfigurationChange + engine.reset()

```swift
NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, ...) {
    engine.reset()
}
```

**失败**：`engine.reset()` 不清除 inputNode 的缓存格式。

### 方案 2：每次录音 rebuildEngine()

```swift
func rebuildEngine() {
    engine.stop()
    engine = AVAudioEngine()  // 全新实例
}
```

**部分成功**：首次录音能用，后续失败。重建 engine 断开了 BT SCO 通道，连续录音来不及重建。

### 方案 3：智能 rebuild（只在设备变更时）

```swift
if currentDeviceUID != requestedUID || needsRebuild {
    rebuildEngine()
}
```

**失败**：warmup 触发了 A2DP→HFP 切换，但 engine 缓存的格式是切换前的。

### 方案 4：installTap(format: nil) 自动协商

```swift
inputNode.installTap(onBus: 0, bufferSize: 4800, format: nil) { ... }
```

**失败**：macOS 上 nil = 缓存格式，不是硬件格式。engine.start() 报 -10868。

### 方案 5：热备 standby + suppressConfigChange

**失败**：warmup 的 start/stop 触发 BT 编解码器切换 → configChange 异步到达 → engine 内部格式过期。

### 方案 6：fresh engine + nil format + 懒创建 converter

**失败**：nil format 在 macOS 上就是用缓存格式，无论 engine 是否全新。

### 方案 7（最终）：CoreAudio AUHAL

**成功**。直接操作硬件 AudioUnit，不经过 AVAudioEngine。

## 最终架构

```
AudioEngine（对外 API 不变：start/stop/warmUp）
  │
  ├── 采集层：CoreAudio AUHAL AudioUnit
  │    ├── AudioComponentInstanceNew(kAudioUnitSubType_HALOutput)
  │    ├── EnableIO → 启用输入 bus 1，禁用输出 bus 0
  │    ├── CurrentDevice → 设置具体设备
  │    ├── StreamFormat → 直接读硬件真实格式（不是缓存！）
  │    └── AURenderCallback → AudioUnitRender 拉取硬件数据
  │
  ├── 转换层：AVAudioConverter（设备原生格式 → 16kHz Int16 PCM）
  │
  └── 监听层：CoreAudio HAL property listeners
       ├── kAudioHardwarePropertyDevices → 设备列表变更
       └── kAudioHardwarePropertyDefaultInputDevice → 默认输入变更 → 平滑重连
```

### AUHAL vs AVAudioEngine 对比

| | AVAudioEngine | AUHAL |
|---|---|---|
| 格式获取 | `outputFormat` — 缓存值，会撒谎 | `AudioUnitGetProperty` — 直接问硬件 |
| BT 兼容 | A2DP→HFP 切换时炸 | 读到什么格式就用什么格式 |
| 设备选择 | 改系统全局默认 | 改当前 AudioUnit |
| 内部状态 | 图协商、格式缓存、自动重连（全部不可靠） | 无内部状态 |
| 适用场景 | 音频处理链（效果器、混音） | 简单采集/播放 |

### 录音中设备切换

监听 `kAudioHardwarePropertyDefaultInputDevice`：

```
录音中 → 默认输入设备变更
  → 销毁旧 AudioUnit
  → 用新设备创建新 AudioUnit → start()
  → 成功：录音继续（丢 ~100-200ms，对转写无感知）
  → 失败：通知 coordinator 中断
```

## 音效播放问题

### 问题

蓝牙耳机下，录音开始的 "Tink" 音效不播放/破声/延迟。

### 原因

```
❌ 错误时序：engine.start() → BT 切到 HFP → 音频输出断开 → play sound → 声音丢失

✅ 正确时序：play sound (A2DP 高品质) → 120ms → engine.start() → BT 切到 HFP → 录音
```

### 解决

音效在 `engine.start()` **之前**播放。此时 BT 还在 A2DP 模式，音频输出正常。播放后等 120ms 让声音播完，再启动引擎。

## 行业现状

| 项目 | 方案 | BT 兼容 |
|---|---|---|
| **AudioKit** | 基于 AVAudioEngine | 有相同 BT bug（Issues #1176, #2130, #2543） |
| **WhisperKit** | 基于 AVAudioEngine | Issue #44 请求改用 AVCaptureSession |
| **OBS Studio** | CoreAudio HAL (C API) | 无 BT 问题 |
| **Capo** | 放弃 AVAudioEngine，回退 AUGraph | 无 BT 问题 |

> "Call me when Logic or Final Cut are based on AVAudioEngine, and we'll go for a skate together in Hell"
> — Capo 开发者

**没有公共 Swift 库解决 AVAudioEngine + BT 问题。** 所有成熟 macOS 音频应用都直接用 CoreAudio。

## 关键教训

1. **macOS 麦克风采集永远用 CoreAudio AUHAL**，不要用 AVAudioEngine
2. 格式信息从 `AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)` 获取，不信任高层 API 缓存
3. BT 音效在麦克风激活**之前**播放（利用 A2DP）
4. 设备变更用 CoreAudio HAL property listener，不用 AVAudioEngineConfigurationChange
5. AVAudioEngine 适合音频处理链，不适合简单采集
