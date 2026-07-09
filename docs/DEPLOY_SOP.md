# Xisper 部署 SOP

从零说明：**改了哪块代码 → 到哪个目录 → 执行哪条命令**。Cloudflare 上 Worker（API）与 Pages（静态站）是不同产物，按表格分别部署即可。

---

## 环境 URL

| 环境 | API 基址 |
|------|----------|
| Beta | `https://xisper-dev.hawkeye-xb.com` |
| Production | `https://xisper.hawkeye-xb.com` |

以下命令均在**仓库根目录**下执行；部署前准备：
- `pnpm install`（根目录）— 首次或依赖更新后
- `wrangler login`（或配置 `CLOUDFLARE_API_TOKEN`）
- macOS 构建需 `.env.build` 配置文件

**重要**：部署 Production 前请先 `git commit` 当前代码，dirty tree 会导致部署失败。

---

## Beta 环境 — 最简命令对照表

| 内容 | 目录 | 最简命令 |
|------|------|----------|
| 主 API | `apps/services` | `bash scripts/deploy.sh services beta` |
| AI Worker（LLM 等） | `apps/ai-worker` | `bash scripts/deploy.sh ai-worker beta` |
| Admin 后台 | `apps/admin` | `cd apps/admin && pnpm run build:beta && npx wrangler pages deploy dist --project-name xisper-admin-beta` |
| 官网 Landing | `apps/landing` | `cd apps/landing && pnpm run build && npx wrangler pages deploy dist --project-name xisper-landing` |
| mac 原生客户端 | `apps/mac-desktop` | `cd apps/mac-desktop && bash scripts/build-and-release.sh beta [版本号]` |

**一次部署两个 Worker（services + ai-worker）：** 在仓库根目录执行
`bash scripts/deploy.sh all beta`
（会写 `deploy-info`、记录 `.deploy-history.log`。）

---

## Production 环境 — 最简命令对照表

| 内容 | 目录 | 最简命令 |
|------|------|----------|
| 主 API | `apps/services` | `bash scripts/deploy.sh services production` |
| AI Worker（LLM 等） | `apps/ai-worker` | `bash scripts/deploy.sh ai-worker production` |
| Admin 后台 | `apps/admin` | `cd apps/admin && pnpm run build:prod && npx wrangler pages deploy dist --project-name xisper-admin` |
| 官网 Landing | `apps/landing` | `cd apps/landing && pnpm run build && npx wrangler pages deploy dist --project-name xisper-landing` |
| mac 原生客户端 | `apps/mac-desktop` | `cd apps/mac-desktop && bash scripts/build-and-release.sh production [版本号]` |

**一次部署两个 Worker：**
`bash scripts/deploy.sh all production`
（`scripts/deploy.sh` 对 production 有确认提示；需先提交代码，dirty tree 会导致部署失败。）

---

## 改了什么 → 要部署什么

| 你修改的代码路径 | 需要执行的部署（上表对应行） |
|------------------|------------------------------|
| `apps/services/**` | 主 API |
| `apps/ai-worker/**` | AI Worker |
| `apps/admin/**` | Admin |
| `apps/landing/**` | Landing |
| `apps/mac-desktop/**` | mac 客户端（本地构建发布） |

若一次改动涉及多目录，按上表**分别**对每条产物执行对应环境的命令。

---

## 可选：Worker 统一脚本等价命令

在仓库**根目录**：

| 环境 | 只发 services | 只发 ai-worker | 两个一起 |
|------|----------------|----------------|----------|
| Beta | `bash scripts/deploy.sh services beta` | `bash scripts/deploy.sh ai-worker beta` | `bash scripts/deploy.sh all beta` |
| Production | `bash scripts/deploy.sh services production` | `bash scripts/deploy.sh ai-worker production` | `bash scripts/deploy.sh all production` |

---

## 部署后自检（API）

| 环境 | 示例 |
|------|------|
| Beta | `curl -s https://xisper-dev.hawkeye-xb.com/api/v1/health` |
| Production | `curl -s https://xisper.hawkeye-xb.com/api/v1/health` |

`/api/v1/info` 可查看 `deploy` 元信息（如 `gitShort`）。

---

## 本仓库 `apps/` 目录说明

当前包含：`services`、`ai-worker`、`admin`、`landing`；mac 客户端在 `apps/mac-desktop`（非 Wrangler 一键部署）。

---

## 相关配置与文档

| 说明 | 路径 |
|------|------|
| Worker 统一部署脚本 | `scripts/deploy.sh` |
| Services / AI Worker 环境 | `apps/services/wrangler.toml`、`apps/ai-worker/wrangler.toml` |
| Admin 的 API / Logto 等 | `apps/admin/src/config.ts` |
| mac 构建细节 | `apps/mac-desktop/scripts/BUILD_SOP.md` |
| 架构总览 | `docs/ARCHITECTURE.md` |

---

## macOS 版本号与推送

构建命令可指定版本号：
```bash
cd apps/mac-desktop
bash scripts/build-and-release.sh beta 0.1.3    # 指定版本
bash scripts/build-and-release.sh beta           # 自动读取 Info.plist 当前版本
```

构建后需手动推送更新（脚本最后会显示 curl 命令）：
```bash
curl -X POST 'https://xisper.hawkeye-xb.com/api/v1/app/mac/updates/promote/production' \
  -H 'x-mac-update-secret: <你的密钥>'
```
