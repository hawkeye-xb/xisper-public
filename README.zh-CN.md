# Xisper

[English](./README.md) · **简体中文**

> 按住快捷键，说话，松开——你说的话就变成文字，出现在你正在用的任何 App 里。

Xisper 是一个常驻菜单栏的 macOS 原生语音输入工具。按住热键说话、松手，Xisper 会把你的语音实时流式转写、用大模型润色，然后直接把结果敲进当前聚焦的应用——编辑器、邮件、聊天窗口，哪儿都行。

本仓库是 Xisper 的**完整源码**：macOS 客户端、Cloudflare Workers 后端、落地页、管理后台。

## 为什么会有这个项目

Mac 上的听写长期只有两种选择：系统自带但没人爱用的那个，或者昂贵、还把你的语音当黑箱的订阅 App。Xisper 想做到：

- **快** —— 实时流式转写，松开热键的瞬间文字就插入。
- **便宜** —— 定价不惩罚重度用户。
- **懂上下文** —— AI 后处理会纠正专业术语、人名、行话；翻译模式让你说一种语言、输出另一种语言。
- **对隐私诚实** —— 我们只做转写和后处理，不囤积你的音频或转写内容。客户端里的埋点只是行为计数（可关闭），绝不采集你的文字。

开源它是一份邀请：看清楚一个生产级语音输入产品从头到尾是怎么搭起来的，从中学习，或者自己跑一套。

## 功能

- **按键说话**：通过全局热键，向任意 macOS App 输入文字。
- **实时流式 ASR**：基于地理位置做服务商路由。
- **AI 后处理**：润色、热词/术语纠正、按角色注入上下文。
- **翻译模式**：说一种语言，插入另一种语言。
- **角色与热词**：教会 Xisper 你所在领域的词汇（法律、医疗、金融、代码……）。
- **自动更新**：基于 Sparkle。
- **用量/配额 + 订阅**计费。

## 架构

Xisper 是一个 pnpm + Turbo monorepo：

| 包 | 是什么 | 技术栈 |
|-----|--------|--------|
| `apps/mac-desktop` | macOS 原生客户端（菜单栏 App） | Swift、XcodeGen、Sparkle |
| `apps/services` | 后端：鉴权、ASR 代理、支付 | Cloudflare Workers、D1、KV、R2 |
| `apps/ai-worker` | LLM 服务商抽象 + 降级链、计量计费 | Cloudflare Workers、D1 |
| `apps/landing` | 营销 / 下载站 | Vue 3、Vite SSG → Cloudflare Pages |
| `apps/admin` | 内部管理后台 | — |

外部服务：**Logto**（身份）、**Creem**（支付）、**Supabase**（鉴权/数据）、**Cloudflare**（Workers/D1/KV/R2/Pages）。

## 快速开始

每个后端包都带一个示例环境变量文件——拷贝一份，填入你自己的凭据：

```bash
# 后端 workers — 密钥
cp apps/services/.dev.vars.example   apps/services/.dev.vars
cp apps/ai-worker/.dev.vars.example  apps/ai-worker/.dev.vars

# 后端 workers — Cloudflare 配置（填入你自己的资源 ID）
cp apps/services/wrangler.toml.example   apps/services/wrangler.toml
cp apps/ai-worker/wrangler.toml.example  apps/ai-worker/wrangler.toml

# macOS 构建机
cp apps/mac-desktop/.env.build.example apps/mac-desktop/.env.build
```

`wrangler.toml.example` 里用的是 `<D1_DATABASE_ID_DEV>` 这类占位符——替换成你自己的 Cloudflare KV namespace ID、D1 database ID、域名和 Logto 租户。真实的 `wrangler.toml` 已被 gitignore，你的 ID 不会被提交。API 密钥永远不要写进 `wrangler.toml`，用 `wrangler secret put`。

```bash
pnpm install
pnpm dev            # 以开发模式运行整个工作区
```

构建 macOS 客户端见 `apps/mac-desktop/scripts/build-and-release.sh`。

## 许可协议

[MIT](./LICENSE) © 2026 Zhaowen Li（[hawkeye-xb](https://github.com/hawkeye-xb)）
