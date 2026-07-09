# Typeless 快捷键系统技术实现文档

> **数据来源**：直接分析 `/Applications/Typeless.app/Contents/` 中的实际代码：
> - `Resources/app.asar` → 解包得到 `dist/main/index.js`（主进程 JS）、`dist/renderer/static/js/*.js`（渲染进程 JS）
> - `Resources/lib/keyboard-helper/build/libKeyboardHelper.dylib`（Swift 原生库）
> - `Resources/lib/input-helper/build/libInputHelper.dylib`（Swift 原生库）
>
> 本文档内容均来自真实源码，非推断。

---

## 目录

1. [技术栈](#1-技术栈)s
2. [整体架构](#2-整体架构)
3. [第一层：Swift libKeyboardHelper.dylib](#3-第一层swift-libkeyboardhelperdylib)
4. [第二层：主进程 JS（KeyboardInputService）](#4-第二层主进程-jskeyboardinputservice)
5. [第三层：渲染进程（XState 录音机 + hC hook）](#5-第三层渲染进程xstate-录音机--hc-hook)
6. [快捷键匹配算法（双层）](#6-快捷键匹配算法双层)
7. [录音触发模式（核心：Tap-vs-Hold）](#7-录音触发模式核心tap-vs-hold)
8. [按键按下的行为](#8-按键按下的行为)
9. [按键抬起的行为](#9-按键抬起的行为)
10. [快捷键规则（实际代码依据）](#10-快捷键规则实际代码依据)
11. [快捷键设置界面（S3 组件）](#11-快捷键设置界面s3-组件)
12. [默认快捷键配置](#12-默认快捷键配置)
13. [原生库 C 接口](#13-原生库-c-接口)
14. [关键时序参数](#14-关键时序参数)

---

## 1. 技术栈

| 层次 | 技术 | 说明 |
|------|------|------|
| 宿主进程 | **Electron** | 桌面应用框架 |
| 键盘监听原生库 | **Swift dylib** (`libKeyboardHelper.dylib`) | 预编译，无需在用户机器构建 |
| JS → 原生桥接 | **koffi**（FFI，非 NAPI）| `require("koffi")` 直接加载 dylib，无需 node-gyp/Rust |
| 底层键盘 API | **CoreGraphics CGEventTap** + Carbon | Swift 封装，用于全局键盘事件拦截 |
| 状态机 | **XState**（渲染进程） | 录音状态由 XState machine 管理 |
| 文字插入 | **Swift libInputHelper.dylib** | Accessibility API 插入文字 |

**Typeless 实现特点**：
- 使用 **koffi FFI + 预编译 Swift dylib**，不需要 Rust 编译步骤
- Swift 库为预编译好的 `.dylib`，部署简单

---

## 2. 整体架构

```
物理按键
    │
    ▼
┌────────────────────────────────────────────────────────────────┐
│  Layer 1: Swift libKeyboardHelper.dylib                        │
│           CGEventTap（Carbon + CoreGraphics）                   │
│                                                                │
│  ShortcutDetector {                                            │
│    targetShortcuts: [["Fn"], ["Fn","Space"], ["Fn","LeftShift"]] │
│    pressingKeycodes: [Int32]                                   │
│    keyPressedTimes: [Int32: Date]                              │
│  }                                                             │
│                                                                │
│  • 实时维护 pressingKeycodes（当前按住的所有键）                  │
│  • 与 targetShortcuts 对比，发现状态变化时触发回调               │
│  • "Blocking event" / "Passing through event"（有拦截能力）     │
│  • 自动重启机制（CGEventTap 超时/用户输入禁用时）                 │
└────────────────────────────────┬───────────────────────────────┘
                                 │ koffi FFI 回调
                                 │ bool KeyboardCallback(int32 keyCode, char* keyName,
                                 │                       int32 paramN, int32 paramA,
                                 │                       char* jsonKeysArray)
                                 ▼
┌────────────────────────────────────────────────────────────────┐
│  Layer 2: Electron 主进程 JS                                    │
│           KeyboardInputService（单例 Ae）                       │
│           + KeyboardHelper 类（单例 Lt）                         │
│                                                                │
│  • 解析 jsonKeysArray（JSON: [{keyCode, keyName, enKeyName}]）   │
│  • 与上次状态对比，仅在状态变化时处理                             │
│  • throttle 16ms（约 60fps）                                    │
│  • 广播 "global-keyboard" 事件到所有渲染窗口                     │
└────────────────────┬───────────────────────────────────────────┘
                     │ IPC: "global-keyboard"（发给 Hub/Onboarding/FloatingBar）
                     │ EventEmitter: "onPressKeyboardKeys"
                     ▼
┌────────────────────────────────────────────────────────────────┐
│  Layer 3: 渲染进程                                              │
│           hC hook（useShortcut）                               │
│           XState 录音机状态机                                   │
│                                                                │
│  hC hook 对每个配置的快捷键（pushToTalk / handlesFreeMode /      │
│  translationMode）独立运行匹配：                                 │
│    • pressingKeys 是否完整包含 targetKeys → isShortcutActive    │
│    • 是否精确匹配（无多余键）→ isFullMatch                       │
│    • 超时 debounce（500ms）→ isMisTouch                         │
│                                                                │
│  XState 状态机：                                                │
│    isShortcutActive(pushToTalk) → PRIMARY_KEY.DOWN / UP         │
│    isShortcutActive(handlesFreeMode) → HANDSFREE_KEY.DOWN       │
└────────────────────────────────────────────────────────────────┘
```

---

## 3. 第一层：Swift libKeyboardHelper.dylib

### 3.1 暴露的 C 接口（koffi 调用）

```c
// 启动键盘监听
bool startMonitor(bool (*callback)(int32_t, char*, int32_t, int32_t, char*))

// 停止键盘监听
void stopMonitor(void)

// 更新目标快捷键列表（JSON 数组，如 [["Fn"], ["Fn","Space"]]）
void updateTargetShortcuts(char* json)

// 清空当前按键状态
void resetPressingKeycodes(void)

// 手动推进事件（用于 NSRunLoop 外调用）
void processEvents(void)

// 设置可访问性权限检查间隔（秒）
void setWatcherInterval(double interval)
```

### 3.2 回调协议

```
bool KeyboardCallback(
    int32_t keyCode,      // 触发快捷键的主键 keyCode（或 sentinel 值）
    char*   keyName,      // 主键名（如 "Fn"）或重启原因字符串
    int32_t paramN,       // 附加参数（与 sentinel 区分用）
    int32_t paramA,       // 附加参数
    char*   jsonKeysArray // JSON: [{ keyCode, keyName, enKeyName }] 当前全部按下的键
)

特殊 sentinel 值：
  keyCode == -8888 && paramN == -8888 && paramA == -8888
    → CGEventTap 崩溃/超时，需重启（keyName = 重启原因）
  keyCode == -9999 && paramN == -9999 && paramA == -9999
    → 清空所有按键状态（如 App 失焦）

返回值 bool：
  true  → 事件已处理（Swift 层可据此决定是否拦截/放行，JS 始终返回 true）
```

### 3.3 重要内部类（反编译自 Swift 符号名）

- **`KeyboardMonitor`**（公开）：管理 CGEventTap 生命周期、watcherTimer（NSTimer）、runLoopSource
- **`ShortcutDetector`**（内部）：维护 `targetShortcuts`、`pressingKeycodes`、`keyPressedTimes`，执行快捷键匹配
- **`KeyboardUtils`**（工具）：`keyCodeToKeyNameMap`、`transformKeyCodeToKeyName`、`qwertyFallbackMap`（键盘布局后备）

### 3.4 关键机制

**可访问性权限自动检测**：
```
NSTimer watcherTimer → 每 5 秒检查一次
→ 若 CGEventTap 被 "tapDisabledByUserInput" 或 "tapDisabledByTimeout" 停用
→ 发送 -8888 sentinel 给 JS → JS 触发 handleMonitorRestart → 重新 startMonitor
```

**键盘布局适配**：
- 每个按键同时记录 `keyName`（当前键盘布局下的名称）和 `enKeyName`（英语 QWERTY 布局下的名称）
- 匹配时两者都会尝试

**事件拦截（Blocking）**：
- 内部有 `"Blocking event: type="` 和 `"Passing through event: type="` 两条分支
- 匹配到 `targetShortcuts` 的按键组合会被 Swift 层拦截（消费），不传递给其他应用
- **JS 回调始终返回 `true`**，Swift 层的拦截决策不依赖 JS 返回值

---

## 4. 第二层：主进程 JS（KeyboardInputService）

### 4.1 KeyboardHelper 类（单例 Lt）

```typescript
class KeyboardHelper {
  // koffi 加载 libKeyboardHelper.dylib
  initializeLibrary() {
    this.lib = koffi.load("lib/keyboard-helper/build/libKeyboardHelper.dylib")
    const callbackProto = koffi.proto("bool KeyboardCallback(int32_t, char*, int32_t, int32_t, char*)")
    this.libStartMonitor          = this.lib.func("startMonitor", "bool", [koffi.pointer(callbackProto)])
    this.libStopMonitor           = this.lib.func("stopMonitor", "void", [])
    this.libUpdateTargetShortcuts = this.lib.func("updateTargetShortcuts", "void", ["char*"])
    this.libResetPressingKeycodes = this.lib.func("resetPressingKeycodes", "void", [])
    this.libProcessEvents         = this.lib.func("processEvents", "void", [])
    this.libSetWatcherInterval    = this.lib.func("setWatcherInterval", "void", ["double"])

    // 注册 JS 回调（koffi 线程安全版）
    this.callback = koffi.register((keyCode, keyName, paramN, paramA, jsonStr) => {
      // sentinel -8888: 重启信号
      if (keyCode === -8888 && paramN === -8888 && paramA === -8888) {
        this.pressingKeys = []
        this.restartCallback?.({ reason: keyName, timestamp: new Date().toISOString() })
        return true
      }
      // sentinel -9999: 清空按键状态
      if (keyCode === -9999 && paramN === -9999 && paramA === -9999) {
        this.pressingKeys = []
        return true
      }
      // 解析当前全部按下的键（去重）
      const keys = JSON.parse(jsonStr)
      const uniqueKeys = deduplicate(keys)  // by keyName

      // 仅在状态变化时通知（同样的按键集合重复到来时跳过）
      if (sameState(this.pressingKeys, uniqueKeys)) return true

      this.pressingKeys = uniqueKeys
      return this.userCallback ? this.userCallback(uniqueKeys) : true
    }, koffi.pointer(callbackProto))
  }

  // 设置目标快捷键（JSON 格式，如 [["Fn"],["Fn","Space"]]）
  setTargetShortcuts(shortcuts: string[][]) {
    this.libUpdateTargetShortcuts(JSON.stringify(shortcuts))
  }
}
```

### 4.2 KeyboardInputService（单例 Ae）

```typescript
class KeyboardInputService extends EventEmitter {
  THROTTLE_INTERVAL = 16   // ms (约 60fps)
  SYNC_INTERVAL     = 50   // ms 周期同步间隔

  handlePressKeyboardEvent = (keys) => {
    this.pendingPressingKeys = keys
    const elapsed = Date.now() - this.lastUpdateTime
    if (elapsed >= this.THROTTLE_INTERVAL) {
      this.cancelScheduledBroadcast()
      this.broadcastKeyboardEvent(keys)
    } else if (!this.throttleTimeoutId) {
      this.scheduleDelayedBroadcast(elapsed)
    }
    return true  // 始终返回 true
  }

  broadcastKeyboardEvent(keys) {
    HubWindow.sendMessage("global-keyboard", keys)
    OnboardingWindow.sendMessage("global-keyboard", keys)
    FloatingBar.sendMessage("global-keyboard", keys)
    this.emit("onPressKeyboardKeys", keys)
    this.lastUpdateTime = Date.now()
  }

  // 更新目标快捷键（从配置读取）
  async reloadKeyboardShortcuts(extraShortcuts = []) {
    const config = store.get("keyboardShortcut")  // { pushToTalk, handlesFreeMode, translationMode, pasteLastTranscript }
    const targets = []
    Object.keys(config).forEach(key => {
      if (key !== "pasteLastTranscript")           // ← pasteLastTranscript 不传给 Swift 监听
        targets.push(splitShortcut(config[key]))   // "Fn+Space" → ["Fn", "Space"]
    })
    targets.push(...extraShortcuts)                // 录音时额外加 [["Escape"]]
    KeyboardHelper.getInstance().setTargetShortcuts(targets)
  }
}
```

**录音期间增加 Escape 监听**：
```typescript
// XState 状态机模块
useEffect(() => {
  if (state.matches("recording_active")) {
    service.reloadKeyboardShortcuts([["Escape"]])  // ← 加入 Escape，允许用户按 Esc 取消录音
  } else {
    service.reloadKeyboardShortcuts()
  }
}, [state])
```

---

## 5. 第三层：渲染进程（XState 录音机 + hC hook）

### 5.1 hC hook（useShortcut）

```typescript
// 渲染进程中的 hC 函数
function useShortcut(shortcutKey, debounceMs = 500, exclusions = []) {
  const config = appSettings.keyboardShortcut[shortcutKey]  // 如 "Fn+Space"
  const targetKeys = config.split("+").map(k => k.trim().toLowerCase())
  const { pressingKeys, pressingKeysWithEn } = usePressingKeys()  // "global-keyboard" 更新
  const [isShortcutActive, setIsShortcutActive] = useState(false)
  const [isMisTouch, setIsMisTouch] = useState(false)

  // 匹配函数
  const checkMatch = (keys) => {
    const pressed = keys.map(k => k.toLowerCase())
    const targetCounts = count(targetKeys)   // 统计目标键频次
    const pressedCounts = count(pressed)
    const areAllTargetKeysPressed = targetKeys.every(k => pressedCounts[k] >= targetCounts[k])
    const isFullMatch = areAllTargetKeysPressed && pressed.length === targetKeys.length
    return { areAllTargetKeysPressed, isFullMatch }
  }

  useEffect(() => {
    const locale = checkMatch(pressingKeys)       // 先用当前键盘布局匹配
    const en = locale.areAllTargetKeysPressed     // 如果已匹配，跳过 EN 布局匹配
      ? { areAllTargetKeysPressed: false, isFullMatch: false }
      : checkMatch(pressingKeysWithEn)            // 否则用 EN QWERTY 布局再匹配
    const result = locale.areAllTargetKeysPressed ? locale : en

    if (result.areAllTargetKeysPressed) {
      const isExcluded = exclusions.some(e => pressedKeys.every(k => e.includes(k)))
      if (result.isFullMatch && !isMisTouch) {
        setIsShortcutActive(true)
        // 启动 debounce 定时器（500ms 后设置 isMisTouch 防误触）
        if (!debounceRef.current) debounceRef.current = setTimeout(() => { debounceRef.current = null }, debounceMs)
      } else if (!debounceRef.current && !isExcluded) {
        setIsShortcutActive(false)
        setIsMisTouch(true)  // 部分匹配或多余键 → 误触
      }
    } else {
      setIsShortcutActive(false); setIsMisTouch(false); debounceRef.current = false
    }
  }, [pressingKeys, pressingKeysWithEn])

  return { isShortcutActive, isMisTouch, shortcut: config }
}
```

### 5.2 XState 录音状态机（关键部分）

```typescript
// 录音机 XState 状态机
{
  states: {
    idle: {
      on: {
        "PRIMARY_KEY.DOWN":     { target: "initializingForTapOrHold" },
        "HANDSFREE_KEY.DOWN":   { target: "initializingForHandsFree" },
        "TRANSLATION_KEY.DOWN": { target: "initializingForTranslation" },
        "CLICK.HANDSFREE_BUTTON": { target: "initializingForHandsFree" }
      }
    },

    // ────────────── 关键状态：等待 Tap 还是 Hold ──────────────
    awaiting_long_press_or_tap: {
      after: {
        [LONG_PRESS_MS]: { target: "recording_active.pushToTalk" }  // ← 超时 → 长按模式
      },
      on: {
        "PRIMARY_KEY.UP":       { target: "recording_active.handsFree" },    // ← 快速抬起 → 免提模式！
        "HANDSFREE_KEY.DOWN":   { target: "recording_active.handsFree" },
        "TRANSLATION_KEY.DOWN": { target: "recording_active.translationModeHandsFree" },
        "WRONG_KEY.DOWN":       { target: "stopping" }
      }
    },
    // ─────────────────────────────────────────────────────────

    recording_active: {
      initial: "pushToTalk",
      states: {
        pushToTalk: {
          entry: ["showDoNotHoldJustPressAlertAction"]  // ← 提示用户"轻按即可，不需要按住"
        },
        handsFree: { ... },
        translationModeHandsFree: { ... }
      },
      on: {
        SOCKET_TICK:      { actions: "socketSendAudioChunk" },
        "RECORD.TIMEOUT": { target: "stopping", actions: w({ onStopTarget: "finishing" }) }
      }
    },

    stopping: { ... },
    finishing: { ... },
    error: { ... }
  }
}

// 连接 hC hook 与 XState 机
const {isShortcutActive: isPttActive, isMisTouch} = hC("pushToTalk", 500, [hfShortcut, transShortcut])
const {isShortcutActive: isHFActive}  = hC("handlesFreeMode", 500)

useEffect(() => {
  if (isPttActive) send({ type: "PRIMARY_KEY.DOWN" })
  else             send({ type: "PRIMARY_KEY.UP" })
  if (isMisTouch)  send({ type: "WRONG_KEY.DOWN" })
}, [isPttActive, isMisTouch])

useEffect(() => {
  if (isHFActive)  send({ type: "HANDSFREE_KEY.DOWN" })
}, [isHFActive])
```

---

## 6. 快捷键匹配算法（双层）

### 6.1 双层匹配示意

```
用户按下 FN 键
    │
    ▼ [Layer 1 - Swift ShortcutDetector]
pressingKeycodes 变化
与 targetShortcuts 对比
→ ["Fn"] 全部匹配 → 触发 JS 回调
（可选：拦截事件，不传给其他 App）
    │
    ▼ [主进程 JS throttle 16ms]
"global-keyboard" 事件广播到渲染进程
    │
    ▼ [Layer 2 - 渲染进程 hC hook]
pressingKeys 收到 [{keyCode:63, keyName:"Fn"}]
targetKeys = ["fn"]
pressed = ["fn"]  ← 全部匹配 + 精确匹配
→ isShortcutActive = true
    │
    ▼ [XState 状态机]
send("PRIMARY_KEY.DOWN")
→ 进入 initializingForTapOrHold
    │
    └─ 用户松开 FN（FN-UP 来临）
       ├── 在 LONG_PRESS_MS 之内 → PRIMARY_KEY.UP → recording_active.handsFree
       └── 超过 LONG_PRESS_MS → 已进入 recording_active.pushToTalk
```

### 6.2 匹配规则

| 规则 | 说明 |
|------|------|
| **全包含匹配** (`areAllTargetKeysPressed`) | 当前按键集合 ⊇ 目标快捷键集合（目标键都被按住） |
| **精确匹配** (`isFullMatch`) | 当前按键集合 = 目标快捷键集合（数量相等，无多余键） |
| **误触** (`isMisTouch`) | `areAllTargetKeysPressed == true` 但 `isFullMatch == false`（有多余键），且 debounce 未到 |
| **键盘布局容错** | 先用当前布局匹配，失败后用 EN QWERTY 布局再试 |
| **排他性** (`exclusions`) | 若更高优先级的快捷键也活跃，当前快捷键被屏蔽 |

---

## 7. 录音触发模式（核心：Tap-vs-Hold）

### 7.1 单快捷键支持两种模式（基于 LONG_PRESS_MS 计时器）

Typeless 的设计亮点：**pushToTalk 快捷键（如 FN）同时支持 Tap 和 Hold 两种触发方式**，区分逻辑在 XState `awaiting_long_press_or_tap` 状态中：

```
按下 FN（PRIMARY_KEY.DOWN）
    │
    ▼ 进入 awaiting_long_press_or_tap
    │
    ├── 超过 LONG_PRESS_MS 无松开
    │       └──► recording_active.pushToTalk（长按录音，按住 = 录，松开 = 停）
    │             入场提示："showDoNotHoldJustPressAlertAction"（建议用户改用轻按）
    │
    └── 在 LONG_PRESS_MS 内松开（PRIMARY_KEY.UP）
            └──► recording_active.handsFree（轻按切换 → 开始录音，等待下次轻按停止）
```

**设计理念**：
- 新手默认会按住 FN → 自动激活长按模式（push-to-talk），同时提示"轻按即可"
- 熟练用户轻按 FN → 免提模式（更高效）
- 无需用户手动切换模式，两种模式统一在同一个快捷键上

### 7.2 `handlesFreeMode` 快捷键（Fn+Space）

`Fn+Space` 是另一条独立的快捷键，触发 `HANDSFREE_KEY.DOWN`：
- 直接跳过 `awaiting_long_press_or_tap`
- 直接进入 `initializingForHandsFree` → `recording_active.handsFree`
- 对应 UI 中的"Ask Anything"（问答模式）特性

### 7.3 翻译模式（Fn+LeftShift）

触发 `TRANSLATION_KEY.DOWN` → `initializingForTranslation` → `recording_active.translationModeHandsFree`

---

## 8. 按键按下的行为

### 8.1 pressingKeys 更新时机

Swift ShortcutDetector 在以下时机触发回调：
1. 有新键被按下，且当前 pressing set 发生变化
2. 有键被松开，且当前 pressing set 发生变化
3. 主进程 JS 做二次去重：若 pressingKeys 集合未变化 → 跳过广播

### 8.2 快捷键激活（keydown 语义）

以 `pushToTalk = "Fn"` 为例：
```
FN 物理按下
→ Swift: pressingKeycodes 加入 FN → 触发回调 [{keyCode:63, keyName:"Fn"}]
→ JS 主进程: throttle 16ms → 广播 "global-keyboard"
→ 渲染进程: hC hook 检测 isFullMatch("fn") = true → isShortcutActive = true
→ XState: PRIMARY_KEY.DOWN → initializingForTapOrHold → awaiting_long_press_or_tap
→ 开始录音初始化（同时启动 LONG_PRESS_MS 计时器）
```

### 8.3 误触检测（isMisTouch）

当按下了"包含目标键但有多余键"的组合时（如配置了 FN，用户按了 FN+T）：
- `areAllTargetKeysPressed = true`（FN 在列）
- `isFullMatch = false`（多了 T）
- `isMisTouch = true` → `WRONG_KEY.DOWN` → `stopping`（停止录音）

---

## 9. 按键抬起的行为

### 9.1 hC hook 的 keyup 语义

按键抬起后，Swift 报告新的 pressingKeys（少了松开的键），`hC hook` 检测到：
- `isFullMatch = false`（目标键不再全部按住）
- `isShortcutActive = false`
- → 触发 `PRIMARY_KEY.UP`

### 9.2 两种模式的抬起行为

| 当前状态 | PRIMARY_KEY.UP 触发时机 | 结果 |
|---------|------------------------|------|
| `awaiting_long_press_or_tap` | 在 LONG_PRESS_MS 之内松开 | → `recording_active.handsFree`（免提模式，继续录音） |
| `recording_active.pushToTalk` | 松开快捷键 | 录音继续（pushToTalk 录音中不因 PRIMARY_KEY.UP 停止？需确认） |
| `recording_active.handsFree` | PRIMARY_KEY.DOWN（再次按下） | 停止录音 + 插入文字 |

---

## 10. 快捷键规则（实际代码依据）

实际验证逻辑在快捷键验证模块的 `F(n)` 函数中：

### 10.1 禁止条件（按优先级）

```typescript
function validateShortcut(keys: string[]): boolean {

  // ① 不能为空
  if (keys.length === 0) return false

  // ② 纯字母/数字/反引号组合不允许单独使用
  if (keys.every(k => /^[a-zA-Z0-9`]+$/.test(k) && k.length === 1))
    return error("error__alphanumeric_only")  // 如 "A", "1+2", "A+B"

  // ③ 最多 3 个键
  if (keys.length > 3) return error("error__too_many_keys")

  // ④ 系统保留快捷键黑名单（精确匹配 joined string）
  const SYSTEM_RESERVED = [
    "LeftCmd+C", "LeftCmd+V", "LeftCmd+X", "LeftCmd+A", "LeftCmd+S",
    "LeftCmd+Z", "LeftCmd+Y", "LeftCmd+W", "LeftCmd+Q", "LeftCmd+R",
    "LeftCmd+N", "LeftCmd+O", "LeftCmd+F", "LeftCmd+G", "LeftCmd+H",
    "LeftCmd+Tab", "LeftCmd+LeftShift+Tab", "LeftCmd+Space",
    "LeftCmd+LeftOption+Escape", "LeftCmd+,",
    "LeftCtrl+C", "LeftCtrl+V", "LeftCtrl+X", "LeftCtrl+A", "LeftCtrl+S",
    "LeftCtrl+Z", "LeftCtrl+Y", "LeftCtrl+W", "LeftCtrl+Q", "LeftCtrl+R",
    "LeftCtrl+N", "LeftCtrl+O", "LeftCtrl+F", "LeftCtrl+G",
    "LeftCtrl+Tab", "LeftCtrl+LeftShift+Tab",
    "LeftOption+Tab", "LeftOption+F4",
    "F1","F2","F3","F4","F5","F6","F7","F8","F9","F10","F11","F12",
    "Escape","Enter","Return","Delete","Backspace","Tab","Space","CapsLock","Pause"
  ]
  if (SYSTEM_RESERVED.includes(keys.join("+"))) return false

  // ⑤ 连续字母不允许（如 A+B 或 B+C 相邻字母）
  const letters = keys.filter(k => /^[A-Z]$/i.test(k)).sort()
  for (let i = 0; i < letters.length - 1; i++)
    if (letters[i+1].charCodeAt(0) - letters[i].charCodeAt(0) === 1) return false

  // ⑥ 连续数字不允许（如 1+2）
  const nums = keys.filter(k => /^[0-9]$/.test(k)).sort()
  for (let i = 0; i < nums.length - 1; i++)
    if (nums[i+1] - nums[i] === 1) return false

  // ⑦ 与其他已配置快捷键冲突
  if (conflictsWithOtherShortcut(keys)) return error("error__already_in_use")

  return true
}
```

### 10.2 允许的独立按键

从代码推断（不在黑名单中，且可通过验证的）：

| 类别 | 允许 | 说明 |
|------|------|------|
| FN 键 | ✅ | 默认快捷键 |
| 右侧修饰键（RightCmd、RightOption 等） | ✅（实际可用） | 不在黑名单中，Swift 能检测到，JS 层不过滤 |
| 左侧修饰键（单独使用） | ⚠️ | 不在黑名单中，技术上可设置，但实际不推荐 |
| 字母（单独） | ❌ | 规则 ② 拦截 |
| 数字（单独） | ❌ | 规则 ② 拦截 |
| F1-F12 | ❌ | 黑名单 |
| Escape、Enter、Tab、Backspace、Space | ❌ | 黑名单 |
| 修饰键 + 字母/数字（非系统保留） | ✅ | 如 `RightOption+A` |

**说明**：右侧修饰键可以作为独立快捷键（Swift 库能检测 RightCmd 等），默认推荐使用 FN 键。

---

## 11. 快捷键设置界面（S3 组件）

```
用户点击快捷键输入框
    │
    ▼ BroadcastChannel("shortcut-editing").postMessage({type: "start-editing"})
      → 所有 hC hook 停止匹配（防止在录入时误触）
      → window.addEventListener("keydown", e.preventDefault())  阻止浏览器默认行为

用户按键
    │
    ▼ pressingKeys 实时更新（来自 "global-keyboard"）
    → r.current 拼接当前按键字符串

用户松开某个键（pressing count 减少）
    │
    ▼ I() 函数：验证当前键组合 F(keys)
    → 通过 → N(keys) → store.set("keyboardShortcut.pushToTalk", "Fn+X")
    → 失败 → 显示错误提示

关闭/确认
    │
    ▼ BroadcastChannel("shortcut-editing").postMessage({type: "stop-editing"})
      → hC hook 恢复匹配
```

---

## 12. 默认快捷键配置

```typescript
// store 中的默认值（对应 keyboardShortcut 字段）
{
  pushToTalk:          "Fn",              // 主录音快捷键
  handlesFreeMode:     "Fn+Space",        // 免提 / Ask Anything 模式
  translationMode:     "Fn+LeftShift",    // 翻译模式
  pasteLastTranscript: "LeftCtrl+LeftCmd+V"  // 粘贴上次转录（不传给 Swift 监听）
}

// 传给 Swift updateTargetShortcuts 的内容（JSON）：
[
  ["Fn"],               // pushToTalk
  ["Fn", "Space"],      // handlesFreeMode
  ["Fn", "LeftShift"]   // translationMode
]
// 注意：pasteLastTranscript 不加入 Swift 监听（用 App 级别快捷键处理）
// 录音期间追加：["Escape"]
```

---

## 13. 原生库 C 接口

### libInputHelper.dylib（文字插入）

```c
void insertText(char* text)           // 在当前光标位置插入文字
void insertRichText(char* rtf, int)   // 插入富文本（RTF 格式）
void deleteBackward()                 // 向后删除（相当于 Backspace）
void* getCurrentInputState()          // 获取当前输入状态
char* getSelectedText()               // 获取选中文字
void  getSelectedTextBySimulateCopyAsync()  // 通过模拟 Cmd+C 获取选中文字（异步）
```

### libContextHelper.dylib（上下文感知）

（具体 API 待分析，用于获取当前应用上下文以优化 AI 后处理）

### libUtilHelper.dylib（工具函数）

（具体 API 待分析，基础工具库）

---

## 14. 关键时序参数

| 参数 | 值 | 位置 | 说明 |
|------|---|------|------|
| `THROTTLE_INTERVAL` | **16ms** | 主进程 `KeyboardInputService` | 约 60fps，键盘事件广播最高频率 |
| `SYNC_INTERVAL` | **50ms** | 主进程 | 周期同步间隔 |
| `LONG_PRESS_MS` | **未知（需运行时确认）** | XState machine `Se.LONG_PRESS_MS` | Tap 和 Hold 的分界计时器 |
| shortcut debounce | **500ms** | 渲染进程 `hC` hook 默认参数 | 防误触 isMisTouch 延迟 |
| watcher interval | **5s** | `setWatcherInterval(5)` | CGEventTap 可访问性权限检查间隔 |
