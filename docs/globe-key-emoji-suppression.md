# Globe 键（FN 键）Emoji 弹窗抑制方案

> 适用版本：macOS 13+（包括 macOS 16 / Tahoe Beta）
> 相关文件：`packages/fn-key-monitor/`、`apps/desktop/src/main/hotkey/input/fn-key-source.ts`

---

## 问题背景

在 macOS 上，Globe/FN 键默认会触发 Emoji 选择器（Apple Silicon Mac 默认行为）。
当用户把 FN 键配置为 Xisper 的快捷键时，按下 FN 键同时会弹出系统的 Emoji 选择器，严重干扰体验。

**为什么 CGEventTap 消费事件不够用？**

Emoji 选择器的触发发生在 **IOKit / HID 层**，早于 CGEventTap 能拦截到的层次。
即使 Rust 层的 `CGEventTap` 把 Globe 的所有事件都消费掉（返回 `null`），系统 HID 层依然会触发 Emoji 选择器。

---

## 错误方案（已废弃）

### 方案一：`defaults write` + `killall`

```bash
defaults write com.apple.HIToolbox AppleFnUsageType -int 0
killall keyboardservicesd
sleep 0.3
killall TextInputSwitcher
```

**为什么无效：**

- `defaults write` 只是写了 `cfprefsd` 的磁盘缓存，不会触发任何通知
- 正在运行的 `TextInputSwitcher`（macOS 16+）通过内部缓存的 `isFnForEmoji` 状态决定是否弹 Emoji，**这个状态不会因为 `defaults write` 而更新**
- `killall` 重启进程后，新进程会重新读取配置。但如果写入没有通过正确的 TIS API 通道，新进程读到的值仍然可能是缓存里的旧值

### 方案二：写入 NSGlobalDomain

```bash
defaults write -g AppleFnUsageType -int 0
```

**为什么无效：**
`keyboardservicesd` 和 `TextInputSwitcher` 读取的是 `com.apple.HIToolbox` 域，完全忽略 NSGlobalDomain 里的同名 key。

---

## 正确方案：HIToolbox TIS API

### 核心发现

通过逆向分析 `TextInputSwitcher` 的二进制（`nm -u`）发现：

```
_TISGetFnUsageType    ← TextInputSwitcher 用这个读取 isFnForEmoji
_TISUpdateFnUsageType ← 系统偏好设置用这个写入
```

`TextInputSwitcher` 并不直接读 `NSUserDefaults`，而是调用 HIToolbox 提供的 `TISGetFnUsageType()` API。
系统偏好设置（"键盘 → 按下 Globe 键"）用 `TISUpdateFnUsageType()` 写入。

**`TISUpdateFnUsageType` 做了两件事：**
1. 把新值写入 `com.apple.HIToolbox` 域的 `AppleFnUsageType` key（通过 CFPreferences）
2. **向所有监听进程广播 TIS 变更通知**，触发 `TextInputSwitcher` 实时刷新 `isFnForEmoji` 状态

这就是为什么在系统偏好设置里改这个选项**立即生效**，无需重启任何进程。

### AppleFnUsageType 值含义

| 值 | 含义 |
|---|---|
| 0 | Do Nothing（什么都不做）|
| 1 | Change Input Source（切换输入法）|
| 2 | Show Emoji & Symbols（显示 Emoji，Apple Silicon 默认）|
| 3 | Start Dictation（启动听写）|

---

## 实现方案

### 1. Rust 层：通过 `dlopen` 调用 HIToolbox API

**文件：** `packages/fn-key-monitor/src/platform/macos.rs`

HIToolbox 是 Carbon.framework 的子框架，无法直接用 `#[link(name = "HIToolbox")]` 链接（链接器找不到路径）。
使用 `dlopen` / `dlsym` 在运行时动态加载：

```rust
// dlopen/dlsym 在 macOS 的 libSystem 中，始终可用
extern "C" {
    fn dlopen(filename: *const i8, flags: i32) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const i8) -> *mut c_void;
}

const HITOOLBOX_PATH: &[u8] =
    b"/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/\
      HIToolbox.framework/Versions/A/HIToolbox\0";

pub fn tis_get_fn_usage_type() -> i32 {
    unsafe {
        let handle = dlopen(HITOOLBOX_PATH.as_ptr() as *const i8, RTLD_LAZY);
        // ... dlsym("TISGetFnUsageType") 并调用
    }
}

pub fn tis_set_fn_usage_type(value: i32) {
    unsafe {
        let handle = dlopen(HITOOLBOX_PATH.as_ptr() as *const i8, RTLD_LAZY);
        // ... dlsym("TISUpdateFnUsageType") 并调用
    }
}
```

### 2. NAPI 层：暴露给 Node.js

**文件：** `packages/fn-key-monitor/src/lib.rs`

新增两个 NAPI 导出函数：

```rust
#[napi]
pub fn get_fn_usage_type() -> i32 { ... }  // 读取当前值

#[napi]
pub fn set_fn_usage_type(value: i32) { ... }  // 写入并广播通知
```

TypeScript 类型定义（`index.d.ts`）同步更新，新增：
```typescript
export declare function getFnUsageType(): number
export declare function setFnUsageType(value: number): void
```

### 3. TypeScript 层：替换 shell 命令

**文件：** `apps/desktop/src/main/hotkey/input/fn-key-source.ts`

**之前（错误做法）：**
```typescript
execSync('defaults write com.apple.HIToolbox AppleFnUsageType -int 0')
execSync('killall keyboardservicesd 2>/dev/null')
execSync('sleep 0.3')
execSync('killall TextInputSwitcher 2>/dev/null')
```

**之后（正确做法）：**
```typescript
// 读取当前值（用于还原）
const getFn = nativeModule.getFnUsageType
const current = getFn()  // e.g. 2 = Emoji

// 写入 0（Do Nothing）并广播 TIS 通知
const setFn = nativeModule.setFnUsageType
setFn(0)  // TextInputSwitcher 立即刷新 isFnForEmoji = false
```

#### "强制通知"保障机制

`TISUpdateFnUsageType` 可能只在值**发生变化**时才广播通知。
如果当前值已经是 0（例如之前用 `defaults write` 写过），调用 `setFnUsageType(0)` 可能不触发通知，导致 TextInputSwitcher 的缓存状态仍然是旧的。

解决方案：如果当前值已经等于目标值，先写一个临时的不同值，再写目标值，强制触发两次通知：

```typescript
if (current === value) {
    setFn(value === 0 ? 1 : 0)  // 短暂设为其他值，不会有可见效果
}
setFn(value)  // 再设为目标值，保证通知一定触发
```

### 4. 生命周期管理

| 时机 | 行为 |
|---|---|
| `start()` 且 `interceptFnKey=true` | 调用 `applyGlobeKeyBehaviorFix()` → 读取并保存当前值 → `setFnUsageType(0)` |
| `stop()` | 调用 `restoreGlobeKeyBehavior()` → `setFnUsageType(savedValue)` |
| `app.before-quit` | 调用 `restoreGlobeKeyBehavior()`（保证崩溃/退出也能还原） |
| `interceptFnKey=false` | 不调用 fix，Globe 键行为不变 |

---

## 文件变更清单

| 文件 | 变更内容 |
|---|---|
| `packages/fn-key-monitor/src/platform/macos.rs` | 新增 `tis_get_fn_usage_type()` / `tis_set_fn_usage_type()`（dlopen 方式） |
| `packages/fn-key-monitor/src/platform/mod.rs` | `mod macos` 改为 `pub mod macos`（允许 lib.rs 访问） |
| `packages/fn-key-monitor/src/lib.rs` | 新增 `#[napi]` 导出：`get_fn_usage_type` / `set_fn_usage_type` |
| `packages/fn-key-monitor/index.d.ts` | 新增两个函数的 TypeScript 类型声明 |
| `apps/desktop/src/main/hotkey/input/fn-key-source.ts` | 完全移除 `execSync` / `defaults write` / `killall`，改用 TIS API |

---

## macOS 版本兼容性

| macOS 版本 | Globe Emoji 触发进程 | 方案有效性 |
|---|---|---|
| macOS 13–15 | `keyboardservicesd` | ✅ `TISUpdateFnUsageType` 同样有效 |
| macOS 16（Tahoe / 26.x）| `TextInputSwitcher` | ✅ 主要修复目标，已验证 |

---

## 已知限制

- `TISUpdateFnUsageType` 是 HIToolbox 的**私有 API**（未公开文档）。Apple 理论上可以在未来版本中修改其行为。目前通过 `dlopen`/`dlsym` 调用，即使函数不存在也只会静默失败，不会崩溃。
- 快捷键编辑和 FN+组合键拦截存在其他独立 bug，需要单独修复（不在本文档范围内）。
