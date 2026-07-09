# SEO & Search Visibility

## 现状

- **主站**: https://xisper-landing.hawkeye-xb.com
- **根域名**: https://xisper.hawkeye-xb.com → 302 重定向到 landing
- **HTTPS**: 正常（Cloudflare 托管）
- **问题**: Google / Bing / 百度搜索域名搜不到 → 未被收录

## 根因

搜索引擎搜不到**不是** HTTPS 问题，而是：

1. 站点未被主动提交到搜索引擎
2. 缺少 `robots.txt`、`sitemap.xml` 等爬虫指引
3. 新站需要时间建立索引

## 已实施

| 项 | 位置 | 说明 |
|---|------|------|
| robots.txt | `apps/landing/public/robots.txt` | 允许爬虫，指向 sitemap |
| sitemap.xml | `apps/landing/public/sitemap.xml` | 首页、隐私、条款 |
| meta 增强 | `apps/landing/index.html` | description, og:*, twitter:card |

## 待执行（需人工）

### 1. Google Search Console

1. 打开 https://search.google.com/search-console
2. 添加资源：`https://xisper-landing.hawkeye-xb.com`（或 xisper.hawkeye-xb.com）
3. 验证所有权：HTML 文件 / DNS / meta 标签
4. 提交 sitemap：`https://xisper-landing.hawkeye-xb.com/sitemap.xml`
5. 可选：请求编入索引（URL 检查 → 请求编入索引）

### 2. Bing Webmaster Tools

1. 打开 https://www.bing.com/webmasters
2. 添加站点：`https://xisper-landing.hawkeye-xb.com`
3. 验证后提交 sitemap

### 3. 百度站长平台

1. 打开 https://ziyuan.baidu.com
2. 添加网站：`https://xisper-landing.hawkeye-xb.com`
3. 验证（文件 / HTML 标签 / CNAME）
4. 提交 sitemap：`https://xisper-landing.hawkeye-xb.com/sitemap.xml`

### 4. 索引时间

- Google: 通常 1–7 天
- Bing: 类似
- 百度: 可能更慢，需持续提交

## 加速收录（提交后执行）

### Ping Sitemap

百度仍支持 sitemap ping，可加速发现：

```bash
curl "https://data.zz.baidu.com/ping?sitemap=https://xisper-landing.hawkeye-xb.com/sitemap.xml"
```

Google 已弃用 ping，需通过 Search Console 提交。Bing 建议用 Webmaster Tools 提交。

### IndexNow（Bing / Yandex 即时索引）

IndexNow 可在几分钟内让 Bing 收录。需生成一个 key 文件放在站点根目录，然后用 API 提交 URL。

- 文档：https://www.indexnow.org/
- 提交示例：`GET https://api.indexnow.org/indexnow?url=...&key=...&keyLocation=...`

### 百度自动推送（可选）

在 landing 的 `index.html` 底部加百度自动推送 JS，用户访问时自动推送给百度：

```html
<script>
(function(){var b=document.createElement("script");b.src="https://zz.bdstatic.com/linksubmit/push.js";b.async=true;document.getElementsByTagName("head")[0].appendChild(b);})();
</script>
```

### 外链入口（让爬虫发现站点）

- GitHub README、仓库描述里放官网链接
- Product Hunt、知乎、V2EX、即刻等产品介绍
- 社交媒体（Twitter、微博）发一条带链接的帖子

爬虫会顺着外链发现并抓取站点。

## 后续优化（可选）

- 结构化数据（JSON-LD）：Product / SoftwareApplication
- 各页面独立 meta（需 vue-meta 或类似）
