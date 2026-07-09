# Xisper 订阅系统 PRD

## 1. 产品概述

Xisper 是一款 macOS 语音转文字工具。采用 Freemium 模式：免费版提供足够的日常用量，Pro 版提供更高配额。

## 2. 用户分层

| Tier | 价格 | 定位 |
|------|------|------|
| Free | $0 | 轻度用户，注册即用 |
| Pro | $X/月 | 重度用户，更高配额 |

> 后续可能增加年付（折扣），但当前只做月付。数据模型应能支持扩展，代码不需要。

## 3. 订阅来源

用户获得 Pro 权限有多种途径，系统必须区分来源：

| 来源 | 标识 | 说明 | 生命周期 |
|------|------|------|----------|
| Creem 支付 | `creem` | 用户通过 Creem 付费订阅 | 跟随 Creem 订阅状态，自动续期/取消/过期 |
| Admin 授权 | `admin` | 运营手动授予 | 指定到期时间，到期自动失效，不续期 |

> 后续可扩展：`promo`（激活码兑换）、`partner`（合作伙伴）等。新增来源只需要加一个 source 值 + 对应的创建入口，不影响核心判定逻辑。

## 4. 功能需求

### 4.1 购买流程

1. 用户在客户端点击「升级 Pro」
2. 客户端调后端接口，后端创建 Creem Checkout Session，返回支付链接
3. 客户端打开浏览器跳转 Creem 支付页
4. 支付成功 → Creem 回调 success 页 → 页面通过 deep link 拉起客户端
5. 同时 Creem 发 Webhook → 后端创建订阅记录 → 用户获得 Pro

**前置检查**：已是 Pro 用户不允许重复购买。

### 4.2 订阅状态

| 状态 | Pro 权限 | 说明 |
|------|----------|------|
| `active` | ✅ 有 | 正常订阅中 |
| `past_due` | ✅ 有 | 付款逾期，宽限期内仍可用 |
| `canceled` | ✅ 有（到 period_end） | 用户已取消，当前周期仍有效 |
| `paused` | ❌ 无 | 暂停（Creem 功能，少见） |
| `expired` | ❌ 无 | 已过期 |

### 4.3 取消订阅

- 用户点击「取消订阅」→ 后端调 Creem API 取消 → 标记 `cancel_at_period_end`
- 当前计费周期内仍享有 Pro 权限
- 周期结束后自动降级为 Free
- 客户端 Settings 展示：「Pro · 将于 YYYY-MM-DD 到期」

### 4.4 Tier 判定规则（核心）

**单一入口**：所有需要知道用户 tier 的地方，都通过同一个函数判定，不直接读 `users.tier`。

判定逻辑：

```
1. 如果 users.tier 是特殊值（enterprise/unlimited）→ 直接返回，不覆盖
2. 查该用户所有订阅记录，筛选"有效订阅"：
   - status IN (active, past_due) → 有效
   - status = canceled AND current_period_end > now → 有效（付了钱的周期）
3. 如果存在任何有效订阅 → tier = pro
4. 如果没有有效订阅 → tier = free
5. 如果判定结果与 users.tier 不一致 → 更新 users.tier（写穿缓存）
```

**关键**：`users.tier` 是缓存，订阅记录是事实。每次判定都以订阅记录为准，顺便修正 `users.tier`。

### 4.5 对账机制

分两层：

**实时对账**（按需）：
- 客户端调 `/rate-limit/status` 或 `/subscription/status` 时触发
- 仅对 `source = creem` 的订阅调 Creem API 验证
- 节流：1 小时内不重复调 Creem API（用 `last_reconciled_at` 字段控制）

**定时对账**（兜底）：
- Cron Trigger，每天一次
- 扫描所有"应该有效但可能过期"的订阅
- `source = creem` → 调 Creem API 确认
- `source = admin/promo` → 检查 `current_period_end` 是否已过期
- 修正 users.tier 与 subscription 状态不一致的情况

### 4.6 变更记录

所有订阅状态变更写入事件表，包括：
- 来源（webhook / cron / admin / tier-resolve）
- 变更前后状态
- 时间戳

用途：用户投诉时查证、数据修正时追溯。不做复杂的监控仪表盘。

### 4.7 Admin 能力

| 操作 | 说明 |
|------|------|
| 授予 Pro | 创建 source=admin 的订阅，指定到期时间 |
| 撤销 Pro | 将 admin 订阅标记为 expired |
| 查历史 | 查某用户的订阅变更事件 |

通过 API 实现，`role = admin` 鉴权。做管理后台 UI。

### 4.8 客户端展示

客户端通过 `/rate-limit/status` 获取以下信息（已有）：

| 字段 | 说明 |
|------|------|
| tier | 当前生效的 tier |
| quota (llm/asr) | 配额用量和剩余 |
| subscription.status | 订阅状态 |
| subscription.currentPeriodEnd | 当前周期到期时间 |
| subscription.cancelAtPeriodEnd | 是否已取消待到期 |

Settings 里展示规则：
- Free 用户：显示「Free」+ 升级按钮
- Pro 正常：显示「Pro」+ 管理订阅按钮
- Pro 已取消待到期：显示「Pro · 将于 XX 到期」+ 重新订阅按钮

## 5. 不做的事

| 项 | 理由 |
|----|------|
| 年付 | 当前只有月付，数据模型预留 plan 字段即可 |
| 免费试用 | Free 版本用量足够 |
| 多支付渠道抽象层 | 只有 Creem，不做 provider 接口 |
| 续费提醒 | Creem 作为 MoR 自己发邮件 |
| 激活码兑换 | 后续做，source 字段已预留扩展 |
| 实时监控仪表盘 | 用 SQL 查 events 表代替 |
