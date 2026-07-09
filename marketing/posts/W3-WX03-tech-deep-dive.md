# WX-03 | 微信公众号 | W3 周末

**标题**：一个前端程序员的后端冒险：Cloudflare 全家桶实战

**关键词**：Cloudflare Workers、D1、R2、KV、Serverless、全栈、独立开发

---

## 正文

### 背景

我是前端开发出身，做的是客户端相关的工作。去年开始用 Vibe Coding 做一个 macOS 语音输入工具 Xisper，除了客户端，后端也得自己搞。

一个人的项目，我不想碰服务器运维。所以选了 Cloudflare 全家桶：Workers + D1 + R2 + KV + Durable Objects。

用了几个月，这篇分享我的真实体验——好的、坏的、和踩的坑。

---

### 为什么选 Cloudflare 而不是 Vercel / AWS

几个考虑：

**成本**。Workers 免费额度很慷慨（每天 10 万请求），D1 免费 5GB，R2 免费 10GB 且不收出流量费。对 Alpha 阶段的个人项目来说，几乎零成本。

**全球边缘网络**。Workers 部署在全球 300+ 节点，对 WebSocket 代理（ASR 语音流）的延迟有帮助。

**全家桶一站式**。数据库、文件存储、KV 缓存、定时任务——全在一个平台上，不用拼凑多个服务。

**无需 Docker / K8s / 服务器管理**。`wrangler deploy` 一条命令就上线。

> 📸 **[图 1]**
> **需要准备**：Cloudflare Dashboard 的项目概览截图（Workers 列表页面或者 D1 数据库页面）。脱敏处理——隐藏 Account ID 等敏感信息。展示"一个人管理的后端架构"。

---

### 用了哪些组件

**Workers（API 服务）**

Xisper 的后端是一个 Workers 应用，用 Hono 框架写路由。主要做：

- 用户鉴权（Logto JWT 验证）
- ASR WebSocket 代理（把前端的音频流转发到 ASR 服务商，同时注入密钥）
- LLM 后处理代理（转发到 DeepSeek，隐藏 API Key）
- 行业角色数据管理
- App 更新管理

核心代码在 `apps/services/`，大概 3000+ 行 TypeScript。

**D1（SQLite 数据库）**

存用户信息、配额数据。D1 的好处是 SQL 兼容性好（就是 SQLite），不需要学新的查询语言。缺点是查询速度不如传统数据库，写入有延迟。但对我的规模完全够用。

**KV（键值缓存）**

存行业角色数据、prompt 模板、应用配置。KV 的读取速度非常快（全球边缘缓存），写入最终一致，适合"写少读多"的场景。

**R2（文件存储）**

存 App 安装包（DMG / ZIP）和自动更新文件。R2 的杀手锏是**零出流量费**——这对分发 App 安装包很关键，不用担心下载量大了账单爆炸。

> 📸 **[图 2]**
> **需要准备**：一张架构图（手画或工具画），展示各个组件之间的关系。大致是：
> - 前端（Electron）→ Workers API
> - Workers → D1（数据库）
> - Workers → KV（缓存/配置）
> - Workers → R2（文件存储）
> - Workers → ASR 服务商（WebSocket 代理）
> - Workers → DeepSeek（LLM 代理）

---

### 踩过的坑

**1/ Workers 的 CPU 时间限制**

免费版每次请求 10ms CPU 时间。听起来很短，但大部分操作（WebSocket 代理、HTTP 转发）是 I/O 密集型的，I/O 等待不算 CPU 时间。实际使用中几乎没触过上限。

但如果你要在 Workers 里做复杂计算（比如大量字符串处理），10ms 可能不够。

**2/ D1 的写入延迟**

D1 的写入不是即时的，跨区域有延迟。如果你的业务需要"写完立即读到"，可能会踩坑。我的方案是写入后前端不依赖服务端确认，用乐观更新。

**3/ KV 的最终一致性**

KV 写入后，全球节点不是立即同步的。如果你修改了行业角色数据，可能某些用户会在几秒内看到旧数据。我用了 stale-while-revalidate 策略：有缓存先用缓存，后台静默更新。

**4/ WebSocket 和 Durable Objects**

Workers 本身支持 WebSocket，但如果需要状态保持（比如 ASR 代理中的心跳管理），需要用 Durable Objects。DO 的概念和传统后端差别很大，学习曲线不低。

> 📸 **[图 3]**
> **需要准备**：一段代码截图，展示 ASR WebSocket 代理的核心逻辑（apps/services/src/routes/asr-proxy.ts 的关键片段）。不需要完整文件，截 WebSocket 握手 + 双向转发的部分，展示"一个前端也能写后端"。

---

### 成本

Alpha 阶段至今，Cloudflare 的账单是：**$0**。

所有用量都在免费额度内。等用户量上来，按 Workers Paid plan $5/月起步，也很合理。

对独立开发者来说，这是我见过的最友好的后端方案之一。

---

### 总结

Cloudflare 全家桶适合什么人？

- 独立开发者 / 小团队
- 不想碰服务器运维
- 对延迟有要求（边缘计算）
- 成本敏感（免费额度慷慨）

不适合什么场景？

- 需要复杂关系型数据库查询
- 需要大量 CPU 密集计算
- 需要强一致性写入

> 📸 **[图 4]**
> **需要准备**：Cloudflare 的用量/计费页面截图，展示 $0 的账单（脱敏处理）。这个数字本身就很有说服力。

下一篇公众号会聊 Xisper 产品本身——精准识别和行业角色的完整使用指南。

---

**标签**：Cloudflare / Workers / Serverless / 独立开发 / 前端全栈 / Vibe Coding
