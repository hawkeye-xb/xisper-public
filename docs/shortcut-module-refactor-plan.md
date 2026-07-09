# 快捷键模块重构实施计划

> 版本：v1.0 · 2026-03-05
> 目标：用单一 Swift dylib（`libXisperKeyboard`）替代 `fn-key-monitor`（Rust NAPI）+ `uiohook-napi`，统一原生键盘监听层，移除定时器 hack，优化免提（toggle）专属交互。

---

## 一、背景与决策

### 1.1 当前架构问题

```
Layer 1（FN 键）:  fn-key-monitor（Rust NAPI）→ FnKeySource.ts
Layer 2（其余键）: uiohook-napi（跨平台 C）→ UiohookSource.ts
Layer 3（匹配）:   ShortcutMatcher.ts（TypeScript）
```

- **两套原生技术**：Rust NAPI + C uiohook，维护成本翻倍
- **uiohook-napi 多余**：跨平台设计，我们只用 macOS，且需要 Accessibility 权限
- **两个 CGEventTap**：Rust 跑一个（监听 FN），uiohook 另起一个（监听其余键），资源浪费
- **无意义的 MIN_PRESS_DURATION**：免提模式不需要最短按压时长，该延迟源自 push-to-talk 的设计

### 1.2 目标架构

```
Layer 1（所有键）: libXisperKeyboard.dylib（Swift）→ KeyboardSource.ts（koffi）
Layer 2（匹配）:   ShortcutMatcher.ts（TypeScript，改动极小）
```

- **单一 CGEventTap**，同时捕获 FN 和所有其余键
- **koffi 已在项目中**（v2.15.1，`packages/native-context` 验证过），无新依赖
- **Swift 构建管线已就绪**（`build.sh` → `swift build -c release`）

### 1.3 技术选型结论

| 方案 | 结论 |
|------|------|
| 沿用 Rust NAPI 扩展 | ❌ 混合语言，koffi/NAPI 两套机制并存 |
| **新建 Swift dylib（推荐）** | ✅ 与 `native-context` 模式完全一致，消除 uiohook 和 Rust 依赖 |

---

## 二、快捷键规则对齐

综合 Typeless 实际代码校验规则 + 当前 Xisper `constants.ts`，制定统一规则。

### 2.1 按键分类

| 类别 | 按键 | 快捷键角色 |
|------|------|-----------|
| **FN/Globe** | Globe 键 | 可单独作为快捷键，或作为修饰键（FN+X） |
| **字母** | A–Z | 必须配合修饰键（Modifier + 字母） |
| **数字** | 0–9 | 必须配合修饰键 |
| **方向键 / 页面控制** | ↑↓←→ / PageUp/Down / Home/End | 可单独或配合修饰键 |
| **符号键** | `[ ] ; ' , . /` | 可单独或配合修饰键 |
| **右侧修饰键** | RightShift / RightCtrl / RightAlt / RightCmd | 可单独作为快捷键主键 |
| **Delete** | Delete（⌦） | 可单独或配合修饰键 |
| **禁止键** | F1–F12 / Escape / Tab / Enter / Backspace / Space（单独）/ CapsLock | ❌ 禁止 |
| **左侧修饰键单独** | LeftShift / LeftCtrl / LeftAlt / LeftCmd | ❌ 禁止单独，仅可作修饰角色 |

### 2.2 组合规则

```
1. 最多 3 个键（与 Typeless 一致）
2. 必须恰好 1 个主键（非修饰键角色）
3. FN+Space 合法（FN 作修饰键，Space 为主键）
4. FN+字母/数字 合法（FN 作修饰键）
5. FN 单独 合法（FN-only 快捷键）
6. 纯字母/数字（无修饰键）❌ 禁止
7. 系统保留快捷键黑名单（见下）
```

### 2.3 系统保留黑名单

以下组合禁止用户配置，避免覆盖系统功能：

```
Cmd+C / Cmd+V / Cmd+X / Cmd+Z / Cmd+A   (剪贴板 / 撤销 / 全选)
Cmd+Q / Cmd+W / Cmd+H / Cmd+M           (退出 / 关窗 / 隐藏 / 最小化)
Cmd+Space                                 (Spotlight)
Cmd+Tab                                   (App Switcher)
Cmd+Shift+3 / Cmd+Shift+4 / Cmd+Shift+5  (截图)
```

### 2.4 constants.ts 变更摘要

**新增：MAC_CARBON_KEYCODES** — 替换部分 `UIOHOOK_KEY_CODES`，作为新 Swift 源的主键码表（Carbon VKC，与 macOS CGEvent 一致）。

> 注意：`UIOHOOK_KEY_CODES` 保留但可逐步废弃，`MAC_KEYCODES` 已存在，视情况合并。

---

## 三、命名规范

不抄 Typeless 内部名称，采用语义清晰的 Xisper 命名。

| 层次 | Typeless 内部名 | Xisper 新名 | 说明 |
|------|----------------|-------------|------|
| Swift 类 | `KeyboardHelper` | `KeyboardEventTap` | CGEventTap 封装 |
| Swift 修饰 | `ShortcutDetector` | 无对应（逻辑在 JS 层） | 检测逻辑保留在 TS |
| C 导出前缀 | `keyboard_*` | `xisper_kb_*` | 与 `xisper_*` 命名族一致 |
| JS 源类 | `KeyboardInputService` | `KeyboardSource` | 替代 FnKeySource + UiohookSource |
| JS 事件类型 | `KeyboardEvent` | `RawKeyEvent` | 避免与 DOM KeyboardEvent 冲突 |
| 事件常量 | 无统一定义 | `KB_EVENT_*` | 明确的枚举值 |
| Globe 行为 | 散落各处 | `GlobeKeyMode` | 统一管理 Globe key 行为 |
| 配置 | `interceptSystem` | `TapConfig` | 结构化拦截配置 |

---

## 四、实施计划

### 总览

```
Phase 1 ─ 新建 packages/keyboard-monitor/     （Swift dylib）
Phase 2 ─ 新建 input/keyboard-source.ts       （JS koffi 桥接层）
Phase 3 ─ 更新 ShortcutMatcher               （微调，移除多余逻辑）
Phase 4 ─ 更新 constants.ts / types.ts        （清理 uiohook 痕迹）
Phase 5 ─ 更新 manager.ts / hotkey-system.ts  （替换 Source 实例）
Phase 6 ─ 移除旧依赖                          （uiohook-napi, fn-key-monitor）
Phase 7 ─ 构建验证 & 打包配置                 （extraResources）
```

---

### Phase 1：新建 `packages/keyboard-monitor/` Swift 包

#### 1.1 目录结构

```
packages/keyboard-monitor/
├── Package.swift
├── build.sh
├── libXisperKeyboard.dylib       ← 构建产物（gitignore）
├── package.json                  ← 仅描述信息，无 npm 脚本依赖
└── Sources/
    └── XisperKeyboard/
        └── KeyboardEventTap.swift
```

#### 1.2 `Package.swift`

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "XisperKeyboard",
  platforms: [.macOS(.v13)],
  targets: [
    .target(
      name: "XisperKeyboard",
      path: "Sources/XisperKeyboard",
      linkerSettings: [
        .linkedFramework("CoreGraphics"),
        .linkedFramework("Carbon"),
        .linkedFramework("HIToolbox"),
      ]
    )
  ]
)
```

#### 1.3 `build.sh`（与 native-context 完全一致的模式）

```bash
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building libXisperKeyboard.dylib..."
swift build -c release

BUILT_LIB=$(find .build -name "libXisperKeyboard.dylib" -not -path "*dSYM*" -type f | head -1)
if [ -z "$BUILT_LIB" ]; then
  echo "ERROR: libXisperKeyboard.dylib not found"
  exit 1
fi

cp "$BUILT_LIB" ./libXisperKeyboard.dylib
echo "Built: $(pwd)/libXisperKeyboard.dylib"
```

#### 1.4 `KeyboardEventTap.swift` 设计

**C 导出 API（xisper_kb_* 前缀）：**

```swift
// 回调签名：eventType / keyCode / modifierFlags
// eventType: 1=keydown, 2=keyup, 3=FN按下, 4=FN抬起
public typealias KeyEventHandler = @convention(c) (Int32, Int32, UInt32) -> Void

// 启动监听
@_cdecl("xisper_kb_start")
public func startKeyboardTap(
  _ callback: KeyEventHandler,
  interceptFn: Bool,
  interceptCodesJson: UnsafePointer<CChar>?   // JSON 数组，FN 组合拦截码
) -> Bool

// 停止监听
@_cdecl("xisper_kb_stop")
public func stopKeyboardTap()

// 运行状态
@_cdecl("xisper_kb_is_running")
public func isKeyboardTapRunning() -> Bool

// 运行时更新拦截配置（无需重启 tap）
@_cdecl("xisper_kb_update_intercept")
public func updateInterceptConfig(
  interceptFn: Bool,
  interceptCodesJson: UnsafePointer<CChar>?
)

// Globe 键行为（读写 AppleFnUsageType）
@_cdecl("xisper_kb_get_globe_mode")
public func getGlobeKeyMode() -> Int32

@_cdecl("xisper_kb_set_globe_mode")
public func setGlobeKeyMode(_ mode: Int32)
```

**核心实现要点（`KeyboardEventTap` Swift class）：**

```swift
class KeyboardEventTap {
  // 单一 CGEventTap，同时捕获 FN 和所有普通键
  // 使用 kCGHIDEventTap（最早拦截点，在 HID 层之后、系统处理之前）

  // FN/Globe 检测：通过 CGEventFlags.maskSecondaryFn 变化检测 FN 按下/抬起
  // （与 fn-key-monitor Rust 实现的检测方式相同）

  // Globe emoji 抑制：
  //   启动时若 interceptFn=true → 调用 xisper_kb_set_globe_mode(0) 写入 AppleFnUsageType
  //   停止时 → 恢复原始值

  // TIS API 调用（HIToolbox）：
  //   TISGetFnUsageType() → 读取当前值
  //   TISUpdateFnUsageType() → 写入新值 + 发送 TIS 通知（与当前 Rust 实现等价）
  //   "Bounce" 机制：若值已是目标值，先写不同值再写目标值，强制触发通知

  // 事件拦截：
  //   返回 nil = 消费事件（不传给系统）
  //   返回 Unmanaged.passRetained(event) = 透传

  // 线程安全：CGEventTap 回调在专用 RunLoop 线程运行
  //   通过 @convention(c) 回调直接调用 JS 注册的 koffi callback
  //   koffi 负责将调用 marshal 到 V8 线程
}
```

**事件类型常量（在 Swift 中定义，在 JS constants.ts 中镜像）：**

```swift
let KB_EVENT_KEYDOWN: Int32 = 1  // 普通键按下
let KB_EVENT_KEYUP:   Int32 = 2  // 普通键抬起
let KB_EVENT_FN_DOWN: Int32 = 3  // Globe/FN 按下
let KB_EVENT_FN_UP:   Int32 = 4  // Globe/FN 抬起
```

> **注意**：FN 键不通过 keydown/keyup 上报，而是单独的 FN_DOWN/FN_UP 事件类型，这样 `ShortcutMatcher` 的 `handleFnPress/handleFnRelease` 接口保持不变。

---

### Phase 2：新建 `input/keyboard-source.ts`

**替代** `fn-key-source.ts` + `uiohook-source.ts`，单一 koffi 桥接层。

```typescript
/**
 * KeyboardSource
 *
 * 通过 koffi FFI 加载 libXisperKeyboard.dylib，
 * 提供统一的键盘事件源（FN + 普通键）。
 *
 * 替代：FnKeySource（Rust NAPI）+ UiohookSource（uiohook-napi）
 */
import koffi from 'koffi'
import path from 'node:path'
import { app } from 'electron'
import log from 'electron-log'

// 事件类型常量（与 Swift 端一致）
export const KB_EVENT_KEYDOWN = 1
export const KB_EVENT_KEYUP   = 2
export const KB_EVENT_FN_DOWN = 3
export const KB_EVENT_FN_UP   = 4

export interface KeyboardSourceEvents {
  onKeyDown: (keyCode: number) => void
  onKeyUp:   (keyCode: number) => void
  onFnDown:  () => void
  onFnUp:    () => void
}

export interface TapConfig {
  interceptFnKey: boolean
  interceptKeyCodesWhenFnDown: number[]   // macOS Carbon VKC
}

export class KeyboardSource {
  // dylib 路径解析（与 native-context 模式一致）
  private resolveDylibPath(): string {
    if (app.isPackaged) {
      return path.join(process.resourcesPath, 'libXisperKeyboard.dylib')
    }
    return path.resolve(
      app.getAppPath(),
      '../../packages/keyboard-monitor/libXisperKeyboard.dylib'
    )
  }

  // 启动：加载 dylib → 注册 koffi 回调 → 调用 xisper_kb_start
  async start(events: KeyboardSourceEvents, config?: TapConfig): Promise<boolean>

  // 停止：调用 xisper_kb_stop → 还原 Globe 行为
  async stop(): Promise<void>

  // 运行时更新拦截配置（无需重启）
  updateConfig(config: TapConfig): void

  // Globe 键行为管理
  getGlobeMode(): number
  setGlobeMode(mode: number): void
}
```

**koffi 回调注册方式：**

```typescript
// 定义回调类型
const KeyEventHandlerType = koffi.proto(
  'KeyEventHandler',
  'void',
  ['int32', 'int32', 'uint32']
)

// 注册 JS 函数为 C 兼容回调
const nativeCallback = koffi.register(
  (eventType: number, keyCode: number, modifierFlags: number) => {
    switch (eventType) {
      case KB_EVENT_KEYDOWN: events.onKeyDown(keyCode); break
      case KB_EVENT_KEYUP:   events.onKeyUp(keyCode);   break
      case KB_EVENT_FN_DOWN: events.onFnDown();          break
      case KB_EVENT_FN_UP:   events.onFnUp();            break
    }
  },
  koffi.pointer(KeyEventHandlerType)
)

// 调用 Swift 启动函数
startFn(nativeCallback, interceptFn, interceptCodesJsonStr)
```

---

### Phase 3：更新 `ShortcutMatcher`（微调）

`ShortcutMatcher` 已经设计良好，**改动极小**：

#### 3.1 移除 `MIN_PRESS_DURATION`（可选优化）

免提模式只关心 `onShortcutDown`（toggle 时机），`onShortcutUp` 由 action handler 忽略。`MIN_PRESS_DURATION = 32ms` 本是为 push-to-talk 设计（确保最短录音时长），免提模式无此需求。

```typescript
// 简化 commitUp：直接调用 executeUp，移除 delay 分支
private commitUp(shortcut: string): void {
  if (this.activeShortcut !== shortcut) return
  this.executeUp(shortcut)
}
```

> 若将来需要支持 push-to-talk，可通过构造参数传入 `minPressDuration`，默认 0。

#### 3.2 `MODIFIER_KEYCODES` 切换到 Carbon VKC

由于新源使用 macOS Carbon 虚拟键码（与 `MAC_KEYCODES` 一致），`MODIFIER_KEYCODES` 中的值需从 uiohook 值切换：

```typescript
// 现在（uiohook 键码）:
SHIFT_LEFT: 42, SHIFT_RIGHT: 54, ...

// 更新后（Carbon VKC）:
SHIFT_LEFT: 0x38, SHIFT_RIGHT: 0x3C, ...
CONTROL_LEFT: 0x3B, CONTROL_RIGHT: 0x3E, ...
ALT_LEFT: 0x3A, ALT_RIGHT: 0x3D, ...
META_LEFT: 0x37, META_RIGHT: 0x36, ...
```

#### 3.3 FN 接口不变

`handleFnPress()` / `handleFnRelease()` 接口保持不变，由 `KeyboardSource` 的 `onFnDown/onFnUp` 回调触发。

---

### Phase 4：更新 `constants.ts` 和 `types.ts`

#### `constants.ts` 变更：

```typescript
// 新增：KB 事件类型常量（与 Swift 同步）
export const KB_EVENT_KEYDOWN = 1
export const KB_EVENT_KEYUP   = 2
export const KB_EVENT_FN_DOWN = 3
export const KB_EVENT_FN_UP   = 4

// 更新 MODIFIER_KEYCODES → Carbon VKC（见 Phase 3.2）

// 新增：Carbon VKC 修饰键码（合并或扩展现有 MAC_KEYCODES）
export const CARBON_MODIFIER_KEYCODES = {
  SHIFT_LEFT:    0x38,
  SHIFT_RIGHT:   0x3C,
  CONTROL_LEFT:  0x3B,
  CONTROL_RIGHT: 0x3E,
  ALT_LEFT:      0x3A,
  ALT_RIGHT:     0x3D,
  META_LEFT:     0x37,
  META_RIGHT:    0x36,
} as const

// 废弃（可保留一段时间用于兼容）:
// UIOHOOK_KEY_CODES（uiohook 专用，新源不再使用）
```

#### `types.ts` 变更：

```typescript
// 删除
export interface FnKeySourceEvents { ... }
export interface UiohookSourceEvents { ... }

// 新增
export interface KeyboardSourceEvents {
  onKeyDown: (keyCode: number) => void
  onKeyUp:   (keyCode: number) => void
  onFnDown:  () => void
  onFnUp:    () => void
}

export interface TapConfig {
  interceptFnKey: boolean
  interceptKeyCodesWhenFnDown: number[]
}
```

---

### Phase 5：更新 `manager.ts` / `hotkey-system.ts`

替换 Source 实例化：

```typescript
// 删除
import { FnKeySource } from './input/fn-key-source'
import { UiohookSource } from './input/uiohook-source'
private fnKeySource = new FnKeySource()
private uiohookSource = new UiohookSource()

// 新增
import { KeyboardSource } from './input/keyboard-source'
private keyboardSource = new KeyboardSource()
```

启动逻辑简化：

```typescript
// 删除：分别启动两个源、两套权限检查、两套 intercept 配置
// 新增：单一启动调用
await this.keyboardSource.start(
  {
    onKeyDown: (kc) => this.matcher.handleKeyDown(kc),
    onKeyUp:   (kc) => this.matcher.handleKeyUp(kc),
    onFnDown:  () => this.matcher.handleFnPress(),
    onFnUp:    () => this.matcher.handleFnRelease(),
  },
  {
    interceptFnKey: hasFnShortcut,
    interceptKeyCodesWhenFnDown: fnComboKeyCodes,
  }
)
```

**Accessibility 权限**：uiohook-napi 需要 Accessibility 权限（因为它在 session 层工作）。新的 CGEventTap（`kCGHIDEventTap`）同样需要，但权限提示和处理逻辑可以统一在 `KeyboardSource` 内部处理，删除 `UiohookSource` 中原有的 2s 轮询检查（改为在 `KeyboardSource.start()` 失败时抛出错误）。

---

### Phase 6：移除旧依赖

#### 6.1 删除文件

```
apps/desktop/src/main/hotkey/input/fn-key-source.ts    ← 删除
apps/desktop/src/main/hotkey/input/uiohook-source.ts   ← 删除
packages/fn-key-monitor/                               ← 可删除或归档
```

#### 6.2 更新 `package.json`

```json
// apps/desktop/package.json
{
  "dependencies": {
    // 删除：
    // "uiohook-napi": "...",
    // "@xisper/fn-key-monitor": "workspace:*",

    // 保留：
    "koffi": "^2.15.1"
  }
}
```

```json
// 根 package.json（monorepo workspace）
{
  "workspaces": [
    // 删除 "packages/fn-key-monitor"（若移除该包）
    // 新增 "packages/keyboard-monitor"
  ]
}
```

#### 6.3 更新 electron-builder 打包配置

```json
// electron-builder config
{
  "extraResources": [
    // 保留
    { "from": "../../packages/native-context/libXisperContext.dylib", "to": "libXisperContext.dylib" },
    // 新增
    { "from": "../../packages/keyboard-monitor/libXisperKeyboard.dylib", "to": "libXisperKeyboard.dylib" }
    // 删除 fn-key-monitor .node 文件的打包规则
  ]
}
```

---

### Phase 7：构建验证 & 测试

#### 7.1 构建顺序

```bash
# Step 1: 构建两个 Swift dylib
cd packages/native-context && bash build.sh
cd packages/keyboard-monitor && bash build.sh

# Step 2: 正常启动应用（开发模式）
cd apps/desktop && pnpm dev
```

#### 7.2 功能验证清单

| 功能 | 验证方法 |
|------|---------|
| FN 单键触发快捷键 | 配置 FN 为触发键，按 FN 单击，确认 onShortcutDown 触发 |
| FN+Key 组合触发 | 配置 FN+A，长按 FN，再按 A，确认立即触发（无定时器等待） |
| 多次 FN+A（FN 不放） | 按 FN+A 后不放 FN，再按 A，确认二次触发（toggle off） |
| Globe emoji 抑制 | 启动后按 Globe 键，确认 emoji 选择器不弹出 |
| 停止后 Globe 恢复 | 关闭监听后，Globe 键行为恢复到原始设置 |
| 事件拦截 | 配置 FN+Space，按 FN+Space，Spotlight 不触发 |
| Accessibility 权限 | 撤销权限后，KeyboardSource.start() 抛出错误并正确处理 |
| 打包产物 | `pnpm build`，确认 `libXisperKeyboard.dylib` 出现在 resources 目录 |

---

## 五、交互模型确认（免提 Toggle）

以 FN+A 为例，完整事件流：

```
用户动作:        [FN↓] ..... [A↓] ... [A↑] ... [A↓] ... [A↑] ... [FN↑]
                   ↑                                              ↑
               可能很久                                      可能永不发生

Swift CGEventTap:
  FN 按下 → callback(KB_EVENT_FN_DOWN, 0, fnFlags)
  A 按下  → callback(KB_EVENT_KEYDOWN, 0x00, fnFlags)   // 0x00 = Carbon VKC for A
  A 抬起  → callback(KB_EVENT_KEYUP, 0x00, fnFlags)
  A 按下  → callback(KB_EVENT_KEYDOWN, 0x00, fnFlags)
  A 抬起  → callback(KB_EVENT_KEYUP, 0x00, fnFlags)

KeyboardSource:
  KB_EVENT_FN_DOWN → matcher.handleFnPress()
  KB_EVENT_KEYDOWN(A) → matcher.handleKeyDown(0x00)
  KB_EVENT_KEYUP(A)   → matcher.handleKeyUp(0x00)
  KB_EVENT_KEYDOWN(A) → matcher.handleKeyDown(0x00)
  KB_EVENT_KEYUP(A)   → matcher.handleKeyUp(0x00)

ShortcutMatcher（无变化）:
  handleFnPress(): fnPressed=true, fnComboUsed=false
  handleKeyDown(A): fnPressed=true, 匹配 FN+A → fnComboUsed=true → commitDown('FN+A')
    → onShortcutDown('FN+A') ✅ 开始录音（toggle on）
  handleKeyUp(A): commitUp('FN+A') → onShortcutUp('FN+A') ← Action handler 忽略
    → activeShortcut=null ✅
  handleKeyDown(A): 再次匹配 FN+A → commitDown('FN+A')
    → onShortcutDown('FN+A') ✅ 停止录音（toggle off）
  handleKeyUp(A): commitUp → onShortcutUp ← 忽略

结论：FN 可以无限期持续按住，A 的每次 keydown 都是一次 toggle，无定时器，无歧义。
```

---

## 六、改动规模评估

| 文件 / 包 | 类型 | 工作量 |
|-----------|------|--------|
| `packages/keyboard-monitor/` | 新建 | ★★★★☆（Swift CGEventTap + TIS API，~300 行） |
| `input/keyboard-source.ts` | 新建 | ★★☆☆☆（koffi 桥接，~150 行） |
| `input/fn-key-source.ts` | 删除 | — |
| `input/uiohook-source.ts` | 删除 | — |
| `shortcut/matcher.ts` | 微改 | ★☆☆☆☆（移除 MIN_PRESS_DURATION 分支，~5 行） |
| `constants.ts` | 更新 | ★★☆☆☆（新增 Carbon VKC，更新 MODIFIER_KEYCODES） |
| `types.ts` | 更新 | ★☆☆☆☆（增删接口，~20 行） |
| `manager.ts` | 更新 | ★★☆☆☆（替换 Source 实例） |
| `hotkey-system.ts` | 微改 | ★☆☆☆☆ |
| `packages/fn-key-monitor/` | 归档/删除 | — |
| 打包配置 | 更新 | ★☆☆☆☆ |

**总结：最大工作量在 Swift dylib 实现（Phase 1）。JS 层改动相对机械，模式与 `context-bridge` 完全一致。**

---

## 七、不在本次计划内的项目

以下事项可在后续迭代处理：

- **快捷键设置 UI**：渲染层快捷键录制（capture mode）逻辑不在本次范围
- **快捷键冲突检测**：系统保留快捷键黑名单校验（当前 validator.ts 可扩展）
- **多快捷键并行**：当前设计支持多个 action 各自有快捷键，无需变更
- **Windows 支持**：明确不在范围（macOS Only）
