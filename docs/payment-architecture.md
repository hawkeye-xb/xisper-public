# Xisper Payment Architecture

## 1. Current State

### Plans

| Plan | Price | Billing Period | Environment variable |
|------|-------|----------------|----------------------|
| Pro Monthly | Operator-defined | every-month | `CREEM_PRODUCT_PRO_MONTHLY` |
| Pro Yearly | Operator-defined | every-year | `CREEM_PRODUCT_PRO_YEARLY` |

### Supported Operations

| Operation | Status | How |
|-----------|--------|-----|
| New subscription | Done | Pricing page → Creem checkout |
| Cancel (at period end) | Done | App Settings → POST /subscription/cancel |
| View billing portal | Done | App Settings → Creem customer portal |
| Upgrade (monthly → yearly) | **Not implemented** | - |
| Downgrade (yearly → monthly) | **Not implemented** | - |
| Pause | Not implemented | - |
| Reactivate after cancel | Partial (Paddle only) | - |

---

## 2. Industry Standard: Subscription Lifecycle

```
                    ┌─────────────────────────────┐
                    │         FREE USER            │
                    └──────────┬──────────────────┘
                               │ Subscribe
                               ▼
                    ┌──────────────────────┐
             ┌──── │       ACTIVE          │ ◄───── Reactivate
             │     └──┬────────┬───────┬──┘
             │        │        │       │
          Upgrade  Downgrade  Pause  Cancel
             │        │        │       │
             ▼        ▼        ▼       ▼
         ┌───────┐ ┌───────┐ ┌─────┐ ┌──────────────┐
         │ACTIVE │ │Queued │ │PAUSE│ │ CANCEL        │
         │(new   │ │(next  │ │     │ │ (at period    │
         │ plan) │ │ cycle)│ │     │ │  end)         │
         └───────┘ └───────┘ └──┬──┘ └──────┬───────┘
                                │            │ Period ends
                             Resume          ▼
                                │     ┌──────────┐
                                └───► │  FREE    │
                                      └──────────┘
```

### Standard Patterns for Each Operation

#### Upgrade (e.g., Monthly → Yearly)

**Industry standard: Immediate switch + proration credit**

1. Calculate remaining value on current plan (e.g., 15 days left of $9.99 = ~$5.00 credit)
2. Apply credit to the new plan price ($79.99 - $5.00 = $74.99 charged now)
3. New billing cycle starts immediately
4. User gets yearly plan benefits right away

**Creem supports this**: `POST /v1/subscriptions/{id}/upgrade` with automatic proration.

#### Downgrade (e.g., Yearly → Monthly)

**Industry standard: Take effect at next billing cycle**

1. User requests downgrade
2. Current plan continues until period end
3. At renewal, switch to new (cheaper) plan
4. No refund issued — user gets what they paid for

**Why not immediate**: Issuing partial refunds on long periods (yearly) creates accounting complexity and customer confusion.

#### Cancel

**Industry standard: Cancel at period end (not immediate)**

1. User requests cancellation
2. Mark `cancel_at_period_end = true`
3. Pro access continues until `current_period_end`
4. After period ends, downgrade to Free
5. Offer "Reactivate" option before period ends

**Already implemented in Xisper.**

#### Pause

**Industry standard: Pause billing, retain account data**

1. Stop auto-renewal
2. Downgrade to Free tier limits
3. Retain all user data and settings
4. User can resume anytime → billing restarts

**Creem supports**: `POST /v1/subscriptions/{id}/pause` and `/resume`.

---

## 3. Recommended Implementation for Upgrade/Downgrade

### Phase 1: Upgrade (Monthly → Yearly) — Recommended Next Step

This is the most common and most valuable flow. Users who want to upgrade are happy customers — make it easy.

**Approach: Use Creem's built-in upgrade API**

```
User clicks "Switch to Yearly" in pricing page
        │
        ▼
Backend: POST /v1/subscriptions/{id}/upgrade
         body: { product_id: "pro_yearly" }
        │
        ▼
Creem handles proration automatically:
  - Credits remaining time on monthly plan
  - Charges difference for yearly plan
  - Returns updated subscription
        │
        ▼
Backend: Update local subscription record
         (plan, current_period_start/end)
        │
        ▼
Webhook: subscription.update → confirm state
```

**Code changes needed:**

1. **Backend**: Add `POST /subscription/upgrade` endpoint
   - Validates user has active monthly subscription
   - Calls Creem upgrade API
   - Updates local DB

2. **Pricing page**: Show "Switch to Yearly" for monthly subscribers instead of "Already on Pro"

3. **Webhook**: Handle `subscription.update` event (already partially handled)

### Phase 2: Downgrade (Yearly → Monthly) — Lower Priority

**Approach: Schedule for next billing cycle**

- Backend: Call Creem's update/scheduled-change API
- Or: Cancel yearly at period end + auto-subscribe to monthly
- Simpler alternative: Let user manage via Creem billing portal

### Phase 3: Pause — Optional

- Only implement if churn data shows users prefer pausing over canceling
- Creem has built-in pause/resume — just need UI

---

## 4. Full Payment Flow Architecture

### Data Flow

```
┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
│ macOS    │     │ Backend  │     │   D1     │     │  Creem   │
│ App      │     │ (CF      │     │ Database │     │  API     │
│          │     │  Worker) │     │          │     │          │
└────┬─────┘     └────┬─────┘     └────┬─────┘     └────┬─────┘
     │                │                │                │
     │ POST /pricing  │                │                │
     │ /ticket        │                │                │
     │ (Bearer JWT)   │                │                │
     │───────────────►│                │                │
     │                │ KV.put(ticket) │                │
     │    {ticket}    │                │                │
     │◄───────────────│                │                │
     │                │                │                │
     │  Open browser  │                │                │
     │  /pricing?t=   │                │                │
     │────────────────┼───►           │                │
     │                │  KV.get       │                │
     │                │  (ticket)     │                │
     │                │  ─────────►   │                │
     │                │               │                │
     │  /pricing/     │               │                │
     │  checkout      │               │                │
     │────────────────┼──►            │                │
     │                │ createCheckout│                │
     │                │───────────────┼───────────────►│
     │                │ checkout_url  │                │
     │                │◄──────────────┼────────────────│
     │                │               │                │
     │  302 → Creem   │               │                │
     │◄───────────────│               │                │
     │                │               │                │
     │  (user pays)   │               │                │
     │                │               │                │
     │                │   Webhook     │                │
     │                │◄──────────────┼────────────────│
     │                │ INSERT sub    │                │
     │                │──────────────►│                │
     │                │ UPDATE user   │                │
     │                │──────────────►│                │
     │                │               │                │
     │  URL scheme    │               │                │
     │  callback      │               │                │
     │◄───────────────│               │                │
     │                │               │                │
     │ reconcile      │               │                │
     │ + refresh      │               │                │
     │───────────────►│               │                │
     │                │ SELECT sub    │                │
     │                │──────────────►│                │
     │  tier=pro      │               │                │
     │◄───────────────│               │                │
```

### Database Schema (Current)

```sql
-- Subscriptions table
subscriptions (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL,
  source                TEXT DEFAULT 'creem',    -- creem|polar|paddle|admin|promo
  plan                  TEXT DEFAULT 'pro_monthly', -- pro_monthly|pro_yearly
  status                TEXT DEFAULT 'active',   -- active|trialing|past_due|canceled|expired|paused
  cancel_at_period_end  INTEGER DEFAULT 0,
  current_period_start  INTEGER,
  current_period_end    INTEGER,
  last_reconciled_at    INTEGER,
  creem_subscription_id TEXT,
  creem_customer_id     TEXT,
  creem_checkout_id     TEXT,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  metadata              TEXT                     -- JSON: extra fields
)

-- Subscription events (audit log)
subscription_events (
  id              TEXT PRIMARY KEY,
  subscription_id TEXT,
  user_id         TEXT NOT NULL,
  trigger         TEXT,     -- webhook|cron|admin|api
  event_type      TEXT,     -- created|activated|canceled|expired|upgraded|...
  before_state    TEXT,     -- JSON snapshot
  after_state     TEXT,     -- JSON snapshot
  detail          TEXT,
  created_at      INTEGER NOT NULL
)
```

### Security Model

| Layer | Mechanism | Exposed? |
|-------|-----------|----------|
| Client → Backend auth | JWT Bearer token (Logto) | Only in HTTP header (never in URL) |
| Client → Pricing page | One-time ticket in KV (5min TTL) | URL param, opaque, auto-expires |
| Backend → Creem | API key (x-api-key header) | Never exposed to client |
| Creem → Backend | HMAC-SHA256 signed webhook | Verified server-side |
| Pricing page HTML | No JavaScript API calls, no tokens | Pure HTML + server-side redirects |

### Reconciliation Strategy

| Trigger | Frequency | What it does |
|---------|-----------|-------------|
| Creem webhook | Real-time | Update subscription status in DB (99% of cases) |
| /subscription/status | On-demand | Query Creem API, sync to DB (throttled 1hr) |
| Cron job | Daily 04:00 UTC | Audit all active subs, fix drift, expire admin/promo subs |
| App launch | Once | Call /subscription/status for reconciliation |
| Payment callback | On payment | reconcileAndRefresh() + 3s retry |
| App activation | Conditional | Only if awaitingPaymentReturn flag is set |

---

## 5. Quota System

| Tier | LLM Calls/Day | ASR Duration/Week | ASR Characters/Week |
|------|--------------|-------------------|-------------------|
| Free | 900 | 75 min | 10,000 |
| Pro | 3,200 | 13.3 hr | 80,000 |
| Enterprise | 3,600 | 20 hr | 150,000 |
| Unlimited | No limit | No limit | No limit |

**Reset schedule:**
- LLM: Daily at 03:00 Beijing Time (19:00 UTC)
- ASR: Weekly, Monday at 03:00 Beijing Time

**Important**: Quota limits are the same for monthly and yearly Pro subscribers. The billing period only affects pricing, not features.

---

## 6. TODO / Roadmap

### Must Have (before production yearly launch)
- [ ] Create yearly product in Creem production dashboard
- [ ] Add production product ID to `creem.ts`
- [ ] Implement upgrade flow (monthly → yearly) using Creem upgrade API
- [ ] Handle `subscription.update` webhook event for plan changes
- [ ] Update pricing page to show "Switch to Yearly (Save 33%)" for monthly subscribers
- [ ] Regression test: full payment flow on beta

### Nice to Have
- [ ] Downgrade flow (yearly → monthly) — can use Creem billing portal as interim solution
- [ ] Pause/Resume subscription
- [ ] Promo codes / coupon support
- [ ] Team/Enterprise plan with seat management
- [ ] Usage-based billing (pay per minute beyond quota)
