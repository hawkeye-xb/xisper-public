# 热词远端托管设计方案

## 设计原则

**服务端权威**：热词以远端为唯一真相。用户操作（增/删/改）直接调 API，请求成功才算落库。客户端本地仅做缓存加速 UI 渲染，不做离线写入、双端合并。

**为什么可以这样做**：
- 热词是工具配置参数，非隐私内容，已经每次发送给 ASR
- 用户已登录，天然有 userId 做数据隔离
- 数据量极小（上限 500 条），全量拉取无压力
- 不需要实时协作、不需要离线可写、不需要 OT/CRDT

**附加价值**：支持导入/导出，用户可以把热词带到其他应用使用。

---

## 1. 数据库迁移

**文件**：`apps/services/migrations/003_add_hotwords.sql`

```sql
CREATE TABLE IF NOT EXISTS hotwords (
  id TEXT PRIMARY KEY,                -- 客户端生成 UUID
  user_id TEXT NOT NULL,
  text TEXT NOT NULL,                 -- 原文（展示用）
  normalized_text TEXT NOT NULL,      -- 服务端计算（trim + 合并空白），仅用于去重
  created_at INTEGER NOT NULL,        -- Unix ms
  updated_at INTEGER NOT NULL,        -- Unix ms
  FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_hotwords_user_id ON hotwords(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_hotwords_user_normalized ON hotwords(user_id, normalized_text);
```

- 无软删除列 — 删除即物理删除，简单直接
- `normalized_text` 唯一约束防重复（同一用户下）
- `id` 由客户端生成（UUID），用于 upsert 幂等

---

## 2. 后端 API

**文件**：`apps/services/src/routes/hotwords.ts`

所有端点需 `authMiddleware`，userId 从 JWT `sub` 获取。

### GET `/api/v1/hotwords`

返回当前用户全部热词列表。

```
Response 200:
{
  "items": [
    { "id": "xxx", "text": "Kubernetes", "createdAt": 1710000000000, "updatedAt": 1710000000000 }
  ],
  "total": 42
}
```

### POST `/api/v1/hotwords`

创建热词（单条或批量）。客户端提供 `id`（UUID），服务端做 upsert 保证幂等。

```
Request:
{
  "items": [
    { "id": "uuid-1", "text": "Kubernetes" },
    { "id": "uuid-2", "text": "gRPC" }
  ]
}

Response 200:
{
  "created": 2,
  "duplicates": []   // normalized_text 冲突时返回已有记录
}

Response 409 (文本重复):
{
  "error": "Duplicate hotword",
  "existing": { "id": "uuid-old", "text": "kubernetes" }
}
```

服务端处理：
1. `text.trim()` + 合并连续空白 → `normalized_text`
2. 检查 `UNIQUE(user_id, normalized_text)` 约束
3. 冲突 → 返回 409 + 已有记录
4. 检查总数上限（500）
5. INSERT

### DELETE `/api/v1/hotwords/:id`

按 id 删除，天然幂等（不存在也返回 200）。

```
Response 200: { "success": true }
```

### PUT `/api/v1/hotwords/:id`

更新单条热词文本。

```
Request: { "text": "K8s" }
Response 200: { "id": "xxx", "text": "K8s", "updatedAt": 1710000000000 }
Response 409: 新文本与已有热词冲突
```

### POST `/api/v1/hotwords/import`

批量导入。接受 JSON 数组，服务端逐条去重后插入。

```
Request:
{
  "items": ["Kubernetes", "gRPC", "WebSocket", "Kubernetes"]  // 纯文本数组
}

Response 200:
{
  "imported": 3,
  "skipped": 1,     // 重复跳过
  "total": 45        // 导入后总数
}
```

### GET `/api/v1/hotwords/export`

导出全部热词，返回纯文本数组（方便用户复制到其他应用）。

```
Response 200:
{
  "items": ["Kubernetes", "gRPC", "WebSocket"],
  "exportedAt": 1710000000000
}
```

### 挂载

`apps/services/src/index.ts` 加一行：

```typescript
app.route('/api/v1/hotwords', hotwordsRouter)
```

---

## 3. 客户端改动

### HotwordItem.swift — 无需改动

现有模型（id, text, createdAt, updatedAt）已经满足需求。不需要额外的 `CloudHotwordItem`。

### HotwordsStore.swift — 改为远端驱动

**去掉**：本地 JSON 文件作为真相源、lastSyncTime、isSyncing、双端合并逻辑。

**改为**：

```
属性:
  items: [HotwordItem]     // 内存缓存，UI 直接绑定
  isLoading: Bool           // 加载状态
  error: String?            // 错误信息（3s 自动清除）

核心方法:
  fetch() async             // GET /hotwords → 刷新 items
  add(text:) async          // POST /hotwords → 成功后刷新
  delete(id:) async         // DELETE /hotwords/:id → 成功后刷新
  update(id:, text:) async  // PUT /hotwords/:id → 成功后刷新
  importTexts(_:) async     // POST /hotwords/import → 成功后刷新
  exportTexts() async       // GET /hotwords/export → 返回文本数组
```

**本地缓存策略**：
- `fetch()` 成功后将 items 写入本地文件（与现有路径一致：`~/Library/Application Support/XisperHotwords/hotwords.json`）
- 启动时先 `load()` 本地缓存渲染 UI，然后 `fetch()` 刷新
- 所有写操作（add/delete/update/import）直接调 API，**成功后**才更新本地缓存
- API 失败 → 显示错误，本地缓存不变

**触发时机**：
1. 启动时：`load()` 本地缓存 → `Task { await fetch() }`
2. 进入 HotwordsView 时：`fetch()` 确保最新
3. 登录后：`fetch()` 拉取云端数据

### HotwordsView.swift — 改动

- add/delete 操作改为 async，显示 loading 状态
- 失败时显示错误提示（已有 3s auto-dismiss 机制）
- 新增导入/导出按钮（现有 Import/Export 菜单改为调 API）
- 导出增加"复制到剪贴板"选项

### ASR 部分 — 无需改动

热词已在 `ASRClient.sendStart(config:)` 中发送。数据源从本地文件变成内存缓存 `HotwordsStore.shared.items`，接口不变。

---

## 4. 数据流

```
┌──────────────────────────────────────────────────────────────┐
│                        用户操作                                │
│   添加热词 / 删除热词 / 编辑热词 / 导入 / 导出                    │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│                   HotwordsStore (客户端)                       │
│                                                              │
│   1. 调 API (POST/DELETE/PUT)                                │
│   2. 成功 → 刷新内存缓存 + 写本地文件                            │
│   3. 失败 → 显示错误，本地不变                                   │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│               Cloudflare Workers (后端)                       │
│                                                              │
│   authMiddleware → userId from JWT                           │
│   D1 数据库: hotwords 表                                      │
│   normalized_text 去重 + 参数化查询                             │
└──────────────────────────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│                     多设备同步                                  │
│                                                              │
│   设备 A 添加热词 → API 写入 D1                                 │
│   设备 B 启动/进入热词页 → GET /hotwords → 自动获取最新           │
└──────────────────────────────────────────────────────────────┘
```

---

## 5. 首次迁移（本地 → 云端）

用户升级到新版本时，本地已有热词需要上传到云端：

1. 启动时检测：本地文件有数据 + 云端为空（`GET` 返回 0 条）
2. 自动执行 `POST /hotwords/import`，将本地热词批量上传
3. 上传成功后，本地文件保留作为缓存（不删除）
4. 此后进入正常的远端驱动模式

若云端已有数据（说明另一台设备已迁移过），则以云端为准，覆盖本地缓存。

---

## 6. 错误处理

| 场景 | 行为 |
|---|---|
| 无网络 | 操作失败提示，本地缓存不变，用户可重试 |
| 401 | 等 AuthManager 刷新 token 后自动重试 |
| 409 (重复) | 提示"热词已存在" |
| 429 (限流) | 提示"操作太频繁，请稍后重试" |
| 500 | 提示"服务器错误，请稍后重试" |
| 首台设备（云端空） | GET 返回空 → 触发本地迁移上传 |
| 新装设备（本地空） | GET 返回云端数据 → 填充本地缓存 |

---

## 7. 安全措施

### 输入验证

| 规则 | 值 |
|---|---|
| 单条热词最大长度 | 64 字符（与客户端一致） |
| 禁止控制字符 | `\x00-\x1F\x7F` |
| ID 格式 | UUID 格式（`^[a-zA-Z0-9\-]{36}$`） |
| 单次批量上限 | 500 条 |
| 单用户热词总数上限 | 500 条 |

### 安全检查清单

- [ ] 所有 SQL 使用参数化查询（`bind()`）
- [ ] userId 从 JWT 提取，所有查询强制 `WHERE user_id = ?`
- [ ] 文本长度 ≤ 64 字符，禁止控制字符
- [ ] ID 格式验证
- [ ] 单用户热词总数 ≤ 500
- [ ] 速率限制（复用已有 `IP_RATE_LIMITER`：120 req/60s）

---

## 8. 需要改动的文件

| 文件 | 操作 | 说明 |
|---|---|---|
| `apps/services/migrations/003_add_hotwords.sql` | 新建 | D1 迁移 |
| `apps/services/src/routes/hotwords.ts` | 新建 | CRUD + 导入/导出路由 |
| `apps/services/src/index.ts` | 改 | 挂载 hotwords 路由 |
| `apps/mac-desktop/Xisper/Managers/HotwordsStore.swift` | 改 | 本地文件驱动 → API 驱动 |
| `apps/mac-desktop/Xisper/Views/HotwordsView.swift` | 改 | async 操作 + 导入导出改为调 API |

---

## 9. 验证方式

**后端**：
```bash
wrangler d1 migrations apply xisper-db --local
# curl 测试各端点
curl -H "Authorization: Bearer $TOKEN" http://localhost:8787/api/v1/hotwords
curl -X POST -H "Authorization: Bearer $TOKEN" -d '{"items":[{"id":"test-uuid","text":"K8s"}]}' http://localhost:8787/api/v1/hotwords
```

**客户端**：
1. 首次升级：本地热词自动上传到云端
2. 第二台设备登录：云端热词自动拉到本地
3. 设备 A 添加热词 → 设备 B 进入热词页看到新热词
4. 导出 → 得到纯文本列表 → 可在其他应用使用
5. 从其他应用复制热词列表 → 导入 → 自动去重
6. 断网时操作失败有提示，恢复网络后可正常操作
