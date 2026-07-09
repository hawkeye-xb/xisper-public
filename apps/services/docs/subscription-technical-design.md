# Xisper 订阅系统 - 技术设计

> 对应 PRD：[subscription-prd.md](./subscription-prd.md)
> 技术栈：Cloudflare Workers + D1 + KV + Hono

---

## 1. 数据模型

### 1.1 subscriptions 表

```sql
CREATE TABLE IF NOT EXISTS subscriptions (
  id                    TEXT PRIMARY KEY,          -- UUID
  user_id               TEXT NOT NULL,             -- FK → users.id
  source                TEXT NOT NULL,             -- 'creem' | 'admin' | 'promo' ...
  plan                  TEXT NOT NULL DEFAULT 'pro_monthly',  -- 预留：pro_yearly 等
  status                TEXT NOT NULL DEFAULT 'active',       -- active | past_due | canceled | paused | expired
  cancel_at_period_end  INTEGER NOT NULL DEFAULT 0,           -- 1 = 到期后取消
  current_period_start  INTEGER,                   -- Unix ms
  current_period_end    INTEGER,                   -- Unix ms
  last_reconciled_at    INTEGER,                   -- Unix ms，上次调外部 API 对账的时间
  -- Creem 专属字段（source='creem' 时有值）
  creem_subscription_id TEXT,
  creem_customer_id     TEXT,
  creem_checkout_id     TEXT,                      -- 用于 checkout.completed 幂等
  -- 通用
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  metadata              TEXT,                      -- JSON，扩展用
  FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_sub_user_id ON subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_sub_status ON subscriptions(status);
CREATE INDEX IF NOT EXISTS idx_sub_creem_sub_id ON subscriptions(creem_subscription_id);
CREATE INDEX IF NOT EXISTS idx_sub_source_status ON subscriptions(source, status);
```

**相对现有 schema 的变更**：
- ✅ 新增 `source` 字段（核心变更）
- ✅ 新增 `last_reconciled_at` 字段（reconcile 节流）
- ✅ `plan` 默认值改为 `pro_monthly`（语义更明确，为年付预留）
- 其余字段保持不变

### 1.2 subscription_events 表（新增）

```sql
CREATE TABLE IF NOT EXISTS subscription_events (
  id                TEXT PRIMARY KEY,        -- UUID
  subscription_id   TEXT,                    -- FK → subscriptions.id，admin 直接改 tier 时可为 null
  user_id           TEXT NOT NULL,           -- FK → users.id
  trigger           TEXT NOT NULL,           -- 'webhook' | 'cron' | 'admin' | 'resolve' | 'api'
  event_type        TEXT NOT NULL,           -- 'created' | 'status_changed' | 'tier_changed' | 'reconciled' | 'expired' | 'revoked'
  before_state      TEXT,                    -- JSON: { status, tier, cancel_at_period_end }
  after_state       TEXT,                    -- JSON: { status, tier, cancel_at_period_end }
  detail            TEXT,                    -- JSON: 补充信息，如 webhook event type、creem response 等
  created_at        INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_sub_events_user ON subscription_events(user_id);
CREATE INDEX IF NOT EXISTS idx_sub_events_sub ON subscription_events(subscription_id);
CREATE INDEX IF NOT EXISTS idx_sub_events_time ON subscription_events(created_at);
```

### 1.3 users 表（不变）

`users.tier` 字段保持不变，作为**缓存**角色。所有读取 tier 的地方通过 `resolveUserTier()` 函数，该函数以 subscriptions 表为事实源，顺便修正 `users.tier`。

---

## 2. 核心模块

### 2.1 Tier 判定（resolveUserTier）

```
resolveUserTier(db, userId) → { tier, subscription }
```

这是整个系统最关键的函数，所有需要知道用户 tier 的地方都调这一个。

**逻辑**：

```
1. SELECT tier FROM users WHERE id = ?
2. 如果 tier IN ('enterprise', 'unlimited') → 直接返回（特殊 tier，不干预）
3. 查有效订阅：
   SELECT * FROM subscriptions
   WHERE user_id = ?
     AND (
       status IN ('active', 'past_due')
       OR (status = 'canceled' AND current_period_end > :now)
     )
   ORDER BY current_period_end DESC NULLS LAST
   LIMIT 1
4. 有结果 → effective_tier = 'pro'
   无结果 → effective_tier = 'free'
5. 如果 effective_tier != users.tier → UPDATE users SET tier = effective_tier
   （同时写 subscription_event，trigger='resolve'）
6. 返回 { tier: effective_tier, subscription: 查到的那条 }
```

**要点**：
- 查所有来源的有效订阅，不分 creem/admin
- 优先取 `period_end` 最晚的（多条有效订阅取最优）
- `users.tier` 与判定结果不一致时自动修正

### 2.2 Reconcile（对账 Creem）

```
reconcileSubscription(db, subscription, creemApiKey, env) → boolean
```

只对 `source = 'creem'` 的订阅执行。

**逻辑**：

```
1. 检查 last_reconciled_at，距今 < 1 小时 → 跳过，返回 false
2. 调 Creem API 查订阅状态
3. 如果 Creem API 不可达 → 跳过（不降级），返回 false
4. 对比本地 vs Creem：status、period_start、period_end、canceled_at
5. 有差异 → 更新本地 subscription + 写 event（trigger='webhook' 或 'cron' 或 'resolve'）
6. 更新 last_reconciled_at = now
7. 返回 true
```

**调用时机**：
- `/rate-limit/status` — 客户端每次启动（受 1 小时节流控制）
- `/subscription/status` — 用户查看订阅详情（受 1 小时节流控制）
- Cron — 每天全量（不受节流，强制刷新）

### 2.3 Webhook 处理

```
POST /api/v1/webhooks/creem
```

**安全**：HMAC-SHA256 签名验证。

**事件处理**：

| 事件 | 处理 |
|------|------|
| `checkout.completed` | 创建 subscription（source='creem'），写 event |
| `subscription.active` / `subscription.paid` | 更新 status/period，写 event |
| `subscription.canceled` / `subscription.expired` | 更新 status，写 event |
| `subscription.paused` | 更新 status='paused'，写 event |
| `subscription.scheduled_cancel` | 设 cancel_at_period_end=1，写 event |
| 未知事件 | 忽略，打 log |

**幂等性**：
- `checkout.completed`：用 `creem_checkout_id` 去重
- 其他事件：本质是 upsert（更新到最新状态），天然幂等

**关键**：Webhook 处理后不需要手动调 `resolveUserTier`。下一次读 tier 时自然会基于最新的 subscription 记录判定。如果需要立即生效（如实时推送），在 Webhook 里直接更新 `users.tier` 作为快速路径。

### 2.4 Cron 对账

```
Cron Trigger: 0 4 * * *  (UTC 04:00，北京 12:00)
```

**逻辑**：

```
-- 第一批：对账 Creem 订阅
SELECT * FROM subscriptions
WHERE source = 'creem'
  AND status IN ('active', 'past_due')
LIMIT 100

→ 逐条调 Creem API 对账（reconcileSubscription，跳过节流）

-- 第二批：过期 admin/promo 订阅
UPDATE subscriptions
SET status = 'expired', updated_at = :now
WHERE source IN ('admin', 'promo')
  AND status = 'active'
  AND current_period_end < :now

→ 写 event

-- 第三批：修正 users.tier 不一致
-- pro 用户没有有效订阅 → 降级
-- free 用户有有效订阅 → 升级
-- （复用 resolveUserTier 逻辑）
```

**CF Workers 约束**：
- Paid plan Cron 最长 15 分钟
- 当前用户量极小，100 条 LIMIT 一次够用
- 用户量增长后：分页处理，或改用 Durable Objects 做长时任务

### 2.5 Event 记录

所有状态变更统一通过一个函数写入：

```
logSubscriptionEvent(db, {
  subscriptionId,    // 可选
  userId,
  trigger,           // 'webhook' | 'cron' | 'admin' | 'resolve' | 'api'
  eventType,         // 'created' | 'status_changed' | 'tier_changed' | ...
  beforeState,       // { status?, tier?, cancelAtPeriodEnd? }
  afterState,        // { status?, tier?, cancelAtPeriodEnd? }
  detail,            // 任意补充 JSON
})
```

---

## 3. API 设计

### 3.1 用户端

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/v1/checkout/create` | 创建 Creem Checkout，返回 `{ checkout_url }` |
| GET | `/api/v1/subscription/status` | 当前订阅详情（触发 reconcile） |
| POST | `/api/v1/subscription/cancel` | 取消订阅（到期生效） |
| GET | `/api/v1/subscription/portal` | 获取 Creem 账单管理链接 |
| GET | `/api/v1/payment/success` | 支付成功落地页（HTML，deep link 拉起客户端） |
| POST | `/api/v1/webhooks/creem` | Creem Webhook 接收端（无 auth，HMAC 验签） |

> `/api/v1/rate-limit/status` 已有，内部调 `resolveUserTier`，不在本模块重复定义。

### 3.2 Admin 端

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/v1/admin/subscription/grant` | 授予 Pro |
| POST | `/api/v1/admin/subscription/revoke` | 撤销 Pro |
| GET | `/api/v1/admin/subscription/events/:userId` | 查用户订阅事件 |

**grant 请求体**：

```json
{
  "user_id": "xxx",
  "source": "admin",
  "days": 30,
  "reason": "补偿用户 xxx 问题"
}
```

**鉴权**：`authMiddleware` + `users.role = 'admin'` 检查。

---

## 4. 数据流

### 4.1 购买流程

```
客户端                    后端 Worker                   Creem
  │                          │                           │
  │── POST /checkout/create ─►│                           │
  │                          │── POST /v1/checkouts ─────►│
  │                          │◄── { checkout_url } ───────│
  │◄── { checkout_url } ─────│                           │
  │                          │                           │
  │── 打开浏览器 ──────────────────────────────────────────►│
  │                          │                           │── 用户支付
  │                          │◄── webhook: checkout.completed ──│
  │                          │  → INSERT subscription    │
  │                          │  → UPDATE users.tier      │
  │                          │  → INSERT event           │
  │                          │                           │
  │◄── deep link ────────────│◄── redirect /payment/success ──│
  │                          │                           │
  │── GET /rate-limit/status ►│                           │
  │◄── { tier: 'pro', ... } ─│                           │
```

### 4.2 对账流程

```
Cron (每天 UTC 04:00)
  │
  ├── 查 source='creem' 且 status IN (active, past_due) 的订阅
  │     └── 逐条调 Creem API 对比 → 有差异则更新 + 写 event
  │
  ├── 查 source IN (admin, promo) 且 period_end < now 的订阅
  │     └── 标记 expired + 写 event
  │
  └── 查 users.tier 与实际订阅不一致的用户
        └── 修正 tier + 写 event
```

### 4.3 Tier 判定流程（每次 API 请求）

```
任何需要 tier 的 API
  │
  └── resolveUserTier(db, userId)
        │
        ├── users.tier = enterprise/unlimited? → 直接返回
        │
        ├── 查有效订阅（所有 source）
        │     │
        │     ├── 有 → tier = pro
        │     └── 无 → tier = free
        │
        └── tier ≠ users.tier? → UPDATE users.tier + 写 event
```

---

## 5. 扩展性设计

当前只做 Creem + Admin 两种来源，但以下扩展点已在架构中预留：

### 5.1 新增订阅来源（如激活码）

1. `source` 字段加一个值，如 `'promo_code'`
2. 新增一个 API 端点：`POST /api/v1/promo/redeem`
3. 该端点创建 `source='promo_code'` 的 subscription，指定 period_end
4. `resolveUserTier` 无需改动——它只看有效订阅，不关心 source
5. Cron 对账中，非 creem 的 source 都走"检查 period_end 是否过期"逻辑，也无需改动

### 5.2 新增 Plan（如年付）

1. `plan` 字段加一个值，如 `'pro_yearly'`
2. `CREEM_PRODUCTS` 配置加一个产品 ID
3. Checkout 时传 `product` 参数选择
4. 其余逻辑不变——plan 不影响 tier 判定，只影响计费周期

### 5.3 新增 Tier（如 Premium）

这是最大的改动，但仍可控：
1. `UserTier` 类型加值
2. `RATE_LIMIT_CONFIG` 加一档配额
3. `resolveUserTier` 中的判定逻辑需要基于 `plan` 映射到不同 tier
4. 需要处理升降级（当前不做）

---

## 6. Migration 计划

基于现有 schema 的增量迁移，两个 migration 文件：

### Migration 006: subscriptions 表加字段

```sql
ALTER TABLE subscriptions ADD COLUMN source TEXT NOT NULL DEFAULT 'creem';
ALTER TABLE subscriptions ADD COLUMN last_reconciled_at INTEGER;
CREATE INDEX IF NOT EXISTS idx_sub_source_status ON subscriptions(source, status);
```

> 存量数据全部标记为 `source = 'creem'`（DEFAULT 值已处理）。

### Migration 007: subscription_events 表

```sql
CREATE TABLE IF NOT EXISTS subscription_events ( ... );
-- 完整 DDL 见 1.2 节
```

---

## 7. Cloudflare Workers 约束与应对

| 约束 | 影响 | 应对 |
|------|------|------|
| Cron 执行时间上限 15min（paid） | 大量用户对账可能超时 | 分页 LIMIT 100，当前量级无压力 |
| D1 无跨表事务 | subscription + users.tier 双写可能不一致 | `resolveUserTier` 每次请求自动修正，最终一致 |
| D1 写入延迟（跨 region replica） | 写后立即读可能读到旧值 | 写操作在同一请求内完成，不跨请求依赖 |
| KV 最终一致性 | 不用于订阅数据 | 订阅数据全部在 D1 |
| Cron 数量限制（free 3 个） | 需要合并 cron | 对账和其他定时任务共用一个 cron entry |

---

## 8. 文件结构（预期）

```
apps/services/src/
├── config/
│   ├── creem.ts              -- Creem API 配置、产品映射、状态映射
│   └── rate-limits.ts        -- 配额配置（不变）
├── routes/
│   ├── payment.ts            -- checkout、webhook、subscription/status、cancel、portal
│   └── admin.ts              -- admin/subscription/grant、revoke、events
├── utils/
│   ├── subscription.ts       -- resolveUserTier（核心判定）
│   ├── subscription-event.ts -- logSubscriptionEvent（事件记录）
│   ├── reconcile.ts          -- reconcileSubscription（Creem 对账）
│   └── rate-limiter.ts       -- 配额检查（不变）
├── cron/
│   └── subscription-audit.ts -- Cron 定时对账逻辑
└── middlewares/
    └── auth.ts               -- 不变
```

现有的 `payment.ts` 里 reconcile 逻辑拆到 `reconcile.ts`，subscription 判定逻辑保留在 `subscription.ts`，事件记录拆到 `subscription-event.ts`。逻辑分层更清晰。
