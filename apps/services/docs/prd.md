📄 AI 应用全栈架构需求规格书 (Standardized SOP)
1. 业务目标
构建一个轻量级、高并发、生产就绪的 AI 后端模板。支持多项目克隆（Copy-paste ready），核心逻辑下沉到边缘计算（Edge Computing），降低延迟与运维成本。

2. 技术栈架构 (Tech Stack)
运行时: Cloudflare Workers

Web 框架: Hono (轻量级、插件化、支持 TypeScript)

身份认证: Logto (支持支付宝、Google、Email SSO，兼容 OIDC)

缓存/限流: Cloudflare KV (Key-Value 存储，处理高频用量统计)

对象存储: Cloudflare R2 (零出站流量费，处理文件/数据暂存)

数据库: Cloudflare D1 (持久化存储用户信息与业务流水)

3. 核心功能模块需求
A. 统一认证网关 (Auth Middleware)
JWT 校验: 所有的 API 请求必须经过 Hono 的中间件，验证 Logto 签发的 JWT。

用户信息同步: 首次登录时，自动在 D1 数据库中创建/更新扩展用户表（User Extension Table），实现 Logto 用户与本地业务逻辑的绑定。

认证方案设计:
- 前端集成: 使用 Logto SDK（支持 Web SPA 和移动端 Native App）
- 认证模式: 支持托管登录页（快速开发）和自定义 UI（纯 SDK 集成）
- 社交登录: 支持支付宝、Google、微信等第三方登录（通过 Logto Connectors 配置）
- 多端支持: Web 和移动端共用统一的认证中心
- Token 流转: 前端获取 Access Token，后端 Workers 验证 Token 并提取用户信息

B. 多租户用量配额管理 (Quota System)
KV 计数器: 使用 KV 存储结构如 project:{id}:user:{id}:usage，实现低延迟的额度查询。

限量逻辑: 每次调用 AI 接口前先查 KV，若超出额度则直接拦截（429 Too Many Requests）。

自动落库: 异步或定时将 KV 中的用量快照同步到 D1，用于长期的账单展示。

C. 增强的文件处理逻辑 (R2 Management)
临时存储池: 所有的上传（ASR 音频、待处理图片）先进入 R2 的 temp/ 目录。

生命周期管理 (Lifecycle): 配合 R2 的规则，自动清理 24 小时内未“转正”的文件，避免空间浪费。

转正逻辑: 当业务流程完成（如 ASR 转写成功），将文件由 temp/ 移动至 final/ 路径并持久化在 D1 中。

D. AI 接口调用抽象 (AI Service Wrapper)
标准化适配器: 封装调用外部 API（如 OpenAI, DeepSeek, 讯飞等）的逻辑。

圆形方程/数学功能: 在处理流程中加入数学解析库（如 LaTeX 处理），支持将结果以标准化公式形式返回。

4. 非功能性需求 (标准化与 SOP)
一键克隆性: 所有的基础设施（KV, R2, D1）必须通过 wrangler.toml 进行标准化绑定。

环境隔离: 标准化 Development, Staging, Production 三套环境的切换流程。

可扩展性: 架构需预留 WebSocket (Durable Objects) 的接入点，即使初期只用 API 形态，后期也能无缝升级。

5. 待优化的架构补丁 (Gap Analysis)
支付集成: 建议预留 Lemon Squeezy 或 Paddle 的 Webhook 接收端，用于自动更新用户的 KV 额度。

错误处理: 需要一套全局的 Error Handler，将边缘侧的报错标准化输出给前端。

日志审计: 建议集成 Cloudflare Logpush，方便多项目部署后的统一监控。