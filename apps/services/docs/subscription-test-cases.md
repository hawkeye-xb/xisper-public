# 订阅系统测试用例

> 对应 PRD：[subscription-prd.md](./subscription-prd.md)
> 对应技术设计：[subscription-technical-design.md](./subscription-technical-design.md)

## 测试约定

- `now` = 当前时间戳
- `future` = now + 30 天
- `past` = now - 1 天
- DB 操作用 D1 SQL 直接验证
- Creem API 用实际 sandbox 环境（test-api.creem.io）

---

## A. Tier 判定（resolveUserTier）

### A1. 无订阅记录的 free 用户

```
前置：users.tier = 'free'，subscriptions 表无该用户记录
操作：调 resolveUserTier(userId)
预期：返回 { tier: 'free', subscription: null }
```

### A2. 有 active 订阅 → pro

```
前置：users.tier = 'free'（或任意值）
      subscriptions: status='active', source='creem', current_period_end=future
操作：调 resolveUserTier(userId)
预期：
  - 返回 { tier: 'pro' }
  - users.tier 被更新为 'pro'
  - subscription_events 写入一条 trigger='resolve', event_type='tier_changed'
```

### A3. canceled 但周期未到期 → 仍是 pro

```
前置：users.tier = 'pro'
      subscriptions: status='canceled', cancel_at_period_end=1, current_period_end=future
操作：调 resolveUserTier(userId)
预期：返回 { tier: 'pro' }，users.tier 不变
```

### A4. canceled 且周期已过期 → 降为 free

```
前置：users.tier = 'pro'
      subscriptions: status='canceled', current_period_end=past
操作：调 resolveUserTier(userId)
预期：
  - 返回 { tier: 'free' }
  - users.tier 被更新为 'free'
  - 写 event
```

### A5. past_due → 仍是 pro（宽限期）

```
前置：subscriptions: status='past_due', current_period_end=future
操作：调 resolveUserTier(userId)
预期：返回 { tier: 'pro' }
```

### A6. paused → free

```
前置：users.tier = 'pro'
      subscriptions: status='paused'
操作：调 resolveUserTier(userId)
预期：返回 { tier: 'free' }，users.tier 降级
```

### A7. expired → free

```
前置：users.tier = 'pro'
      subscriptions: status='expired'
操作：调 resolveUserTier(userId)
预期：返回 { tier: 'free' }，users.tier 降级
```

### A8. 特殊 tier 不被覆盖

```
前置：users.tier = 'enterprise'，无订阅记录
操作：调 resolveUserTier(userId)
预期：返回 { tier: 'enterprise' }，不查 subscriptions 表
```

### A9. 多条订阅 — 取有效的

```
前置：用户有两条订阅：
  - sub1: status='canceled', current_period_end=past（旧的，已过期）
  - sub2: status='active', current_period_end=future（新的）
操作：调 resolveUserTier(userId)
预期：返回 { tier: 'pro' }，基于 sub2 判定
```

### A10. 多条订阅 — 取 period_end 最晚的

```
前置：用户有两条有效订阅：
  - sub1: source='creem', status='active', current_period_end=future（30天后）
  - sub2: source='admin', status='active', current_period_end=future+60天
操作：调 resolveUserTier(userId)
预期：返回的 subscription 是 sub2（period_end 更晚）
```

---

## B. Source 隔离

### B1. admin 订阅不被 Creem reconcile 覆盖

```
前置：
  - subscriptions: source='admin', status='active', current_period_end=future
  - users.tier = 'pro'
操作：调 /rate-limit/status（会触发 reconcile）
预期：
  - 不调 Creem API（source != 'creem'）
  - users.tier 仍是 'pro'
  - 订阅记录不变
```

### B2. admin 订阅到期自动失效

```
前置：subscriptions: source='admin', status='active', current_period_end=past
操作：Cron 对账执行
预期：
  - status 更新为 'expired'
  - users.tier 降为 'free'
  - 写 event
```

### B3. creem 订阅被 reconcile 更新

```
前置：
  - subscriptions: source='creem', status='active', last_reconciled_at=2小时前
  - Creem API 返回 status='canceled'
操作：调 /subscription/status（触发 reconcile）
预期：
  - 本地 status 更新为 'canceled'
  - 写 event
  - 如果 period_end > now → tier 仍是 pro
  - 如果 period_end < now → tier 降为 free
```

---

## C. Reconcile 节流

### C1. 1 小时内不重复调 Creem API

```
前置：subscriptions: source='creem', last_reconciled_at=30分钟前
操作：调 /subscription/status
预期：不调 Creem API，用本地数据返回
```

### C2. 超过 1 小时 → 调 Creem API

```
前置：subscriptions: source='creem', last_reconciled_at=2小时前
操作：调 /subscription/status
预期：调 Creem API，更新 last_reconciled_at=now
```

### C3. Cron 不受节流限制

```
前置：subscriptions: source='creem', last_reconciled_at=10分钟前
操作：Cron 对账执行
预期：仍然调 Creem API（Cron 强制刷新）
```

---

## D. Webhook

### D1. checkout.completed — 正常创建订阅

```
操作：发送 checkout.completed webhook，metadata.user_id 有效
预期：
  - 新建 subscription: source='creem', status='active'
  - users.tier = 'pro'
  - 写 event: trigger='webhook', event_type='created'
```

### D2. checkout.completed — 幂等（重复 webhook）

```
前置：已有 creem_checkout_id='chk_123' 的 subscription
操作：再次发送相同 checkout.completed（creem_checkout_id='chk_123'）
预期：不创建重复记录，返回 200
```

### D3. subscription.canceled

```
前置：有 active 的 creem 订阅
操作：发送 subscription.canceled webhook
预期：
  - status 更新为 'canceled'
  - 如果是当前周期内 → users.tier 仍 'pro'
  - 写 event
```

### D4. subscription.active — 续期

```
前置：有 canceled 的 creem 订阅（用户重新订阅）
操作：发送 subscription.active webhook，带新的 period_start/period_end
预期：
  - status 更新为 'active'
  - cancel_at_period_end = 0
  - period 日期更新
  - users.tier = 'pro'
  - 写 event
```

### D5. subscription.scheduled_cancel

```
操作：发送 subscription.scheduled_cancel webhook
预期：
  - cancel_at_period_end = 1
  - status 不变（仍 active）
  - 写 event
```

### D6. 签名验证失败

```
操作：发送 webhook，签名错误
预期：返回 401，不处理
```

### D7. 未知事件类型

```
操作：发送 eventType='subscription.unknown' 的 webhook
预期：返回 200，打 log，不报错
```

---

## E. Checkout

### E1. free 用户正常创建 checkout

```
前置：users.tier = 'free'，无 active 订阅
操作：POST /checkout/create
预期：返回 { success: true, checkout_url: '...' }
```

### E2. pro 用户不能重复购买

```
前置：users.tier = 'pro'
操作：POST /checkout/create
预期：返回 400，error: 'Already subscribed'
```

### E3. 有 active 订阅不能重复购买

```
前置：users.tier 可能因 bug 还是 'free'，但有 active 订阅
操作：POST /checkout/create
预期：返回 400，error: 'Active subscription already exists'
```

---

## F. 取消订阅

### F1. 正常取消

```
前置：有 active 的 creem 订阅
操作：POST /subscription/cancel
预期：
  - 调 Creem API 取消
  - cancel_at_period_end = 1
  - status 仍是 'active'
  - 写 event
```

### F2. 没有 active 订阅

```
前置：无 active 订阅（或只有 expired 的）
操作：POST /subscription/cancel
预期：返回 404
```

---

## G. Admin API

### G1. 授予 Pro

```
操作：POST /admin/subscription/grant { user_id, days: 30, reason: '测试' }
预期：
  - 新建 subscription: source='admin', status='active', current_period_end=now+30天
  - users.tier = 'pro'
  - 写 event: trigger='admin', event_type='created'
```

### G2. 授予 Pro — 用户已有 creem 订阅

```
前置：用户已有 creem active 订阅
操作：POST /admin/subscription/grant { user_id, days: 90 }
预期：
  - 新建 admin 订阅（与 creem 订阅共存）
  - resolveUserTier 取 period_end 更晚的那个
```

### G3. 撤销 admin Pro

```
前置：用户有 source='admin' 的 active 订阅
操作：POST /admin/subscription/revoke { user_id }
预期：
  - admin 订阅 status = 'expired'
  - 如果没有其他有效订阅 → users.tier = 'free'
  - 写 event: trigger='admin', event_type='revoked'
```

### G4. 撤销不影响 creem 订阅

```
前置：用户同时有 creem active + admin active 订阅
操作：POST /admin/subscription/revoke { user_id }
预期：
  - 只撤销 admin 订阅
  - creem 订阅不受影响
  - users.tier 仍 'pro'（因为 creem 订阅有效）
```

### G5. 非 admin 用户调 admin API

```
前置：users.role = 'user'（非 admin）
操作：POST /admin/subscription/grant
预期：返回 403
```

### G6. 查事件历史

```
前置：用户有多次订阅变更
操作：GET /admin/subscription/events/:userId
预期：返回按时间倒序的 event 列表，包含 trigger、event_type、before/after state
```

---

## H. Cron 对账

### H1. creem 订阅 — Creem 侧已取消

```
前置：本地 status='active'，Creem API 返回 status='canceled'
操作：Cron 执行
预期：本地更新为 'canceled'，写 event
```

### H2. creem 订阅 — Creem API 不可达

```
前置：本地 status='active'
操作：Cron 执行，Creem API 返回 5xx
预期：跳过该条，不降级，不写 event，打 log
```

### H3. admin 订阅过期

```
前置：source='admin', status='active', current_period_end=past
操作：Cron 执行
预期：status='expired'，users.tier='free'（如无其他有效订阅），写 event
```

### H4. users.tier 不一致修正 — pro 但无有效订阅

```
前置：users.tier='pro'，但所有订阅都已 expired
操作：Cron 执行
预期：users.tier 降为 'free'，写 event
```

### H5. users.tier 不一致修正 — free 但有有效订阅

```
前置：users.tier='free'，但有 active 订阅（webhook 丢失场景）
操作：Cron 执行
预期：users.tier 升为 'pro'，写 event
```

---

## I. 客户端展示验证

### I1. Free 用户

```
操作：GET /rate-limit/status
预期响应包含：
  tier: 'free'
  subscription: null 或 hasSubscription: false
```

### I2. Pro 正常用户

```
操作：GET /rate-limit/status
预期响应包含：
  tier: 'pro'
  subscription.status: 'active'
  subscription.cancelAtPeriodEnd: false
```

### I3. Pro 已取消待到期

```
操作：GET /rate-limit/status
预期响应包含：
  tier: 'pro'
  subscription.status: 'canceled'（或 'active' + cancelAtPeriodEnd: true）
  subscription.currentPeriodEnd: 未来时间戳
```

### I4. 刚过期降级

```
前置：订阅刚过期
操作：GET /rate-limit/status
预期：
  tier: 'free'
  配额按 free 标准返回
```

---

## 测试执行顺序建议

```
1. A 系列 — 先确保核心判定逻辑正确（纯函数，不依赖外部）
2. B 系列 — 验证 source 隔离（核心架构变更）
3. D 系列 — Webhook 处理（用 Creem sandbox）
4. E + F — Checkout 和取消（端到端）
5. G 系列 — Admin API
6. C 系列 — Reconcile 节流
7. H 系列 — Cron 对账
8. I 系列 — 客户端展示（集成验证）
```
