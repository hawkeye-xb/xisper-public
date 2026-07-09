# Mac Native 本地打包与发布 SOP

与 `build-and-release.sh` 同目录，人工按此清单操作即可。

---

## 一次性准备（每台电脑）

1. 已 clone 仓库，能正常开发。
2. 工具：`brew install xcodegen create-dmg`；已安装 Xcode 并接受许可。
3. 机密配置：将 `.env.build` 放到 `apps/mac-desktop/.env.build`（可从安全备份目录复制）。**不要提交 git。**
4. 签名：钥匙串中须有 **Developer ID Application** 证书。检查：
   ```bash
   security find-identity -v -p codesigning
   ```
5. 公证：把 Apple 账号凭据写入钥匙串（脚本使用 profile 名 `xisper-notarize`）：
   ```bash
   xcrun notarytool store-credentials "xisper-notarize" \
     --apple-id "<你的 Apple ID 邮箱>" \
     --password "<App 专用密码>" \
     --team-id "<Team ID>"
   ```
6. Sparkle：`.env.build` 中填写 `SPARKLE_PRIVATE_KEY`。至少用 Xcode 完整编译一次工程，确保 SPM 拉下 Sparkle，DerivedData 里存在 `generate_appcast`。
7. R2 上传：登录 Cloudflare（wrangler 能写对应 bucket）：
   ```bash
   npx wrangler login
   ```
8. 证书信任：若 Xcode 报 *Invalid trust settings*，需清除该证书在「用户」域的自定义信任（勿在钥匙串里把证书设为「始终信任」）。团队曾用空 `trustList` 的 trust-settings plist 导入方式清空覆盖。

---

## 每次发版

1. **拉代码**
   ```bash
   cd /path/to/Xisper
   git pull
   ```

2. **定版本号**  
   例如 `0.1.3`。**beta 不必写在版本号里**；beta / production 由脚本第一个参数决定，对应不同 Bundle ID 与 R2 路径。

3. **执行打包**（在 `apps/mac-desktop` 下）：
   ```bash
   cd apps/mac-desktop
   bash scripts/build-and-release.sh beta <版本号>
   ```
   示例：
   ```bash
   bash scripts/build-and-release.sh beta 0.1.3
   ```
   正式渠道（production）：
   ```bash
   bash scripts/build-and-release.sh production <版本号>
   ```

4. **脚本自动完成**（无需手点）  
   `xcodegen` → 写 `Info.plist` 版本与 Feed → Archive → Export → `create-dmg` → 公证 + staple → 生成 `appcast` → 上传 DMG 与 `appcast-pre.xml` 到 R2 的 `mac-<channel>/` → **删除本地 `build/` 目录**。

5. **对外生效（可选）**  
   上传后默认**未**对用户推送更新。需要上线时，执行脚本结尾打印的 **promote** `curl`（`x-mac-update-secret` 来自 `.env.build` 的 `MAC_UPDATE_PROMOTE_SECRET`）。

6. **抽查（可选）**  
   R2 上应有：`mac-beta/<DMG 文件名>`、`mac-beta/appcast-pre.xml`（beta 示例）。需要时再 curl 对应环境的 feed 看 XML。

---

## 速查

| 目的     | 命令 |
|----------|------|
| 打 beta 包 | `bash scripts/build-and-release.sh beta <版本号>` |
| 打正式渠道包 | `bash scripts/build-and-release.sh production <版本号>` |

Release 下连 dev 还是 prod 后端，由 **Bundle ID 是否以 `.beta` 结尾** 决定，见 `Xisper/Core/Environment.swift`。

---

## 常见问题

| 现象 | 处理 |
|------|------|
| 找不到 `generate_appcast` | 用 Xcode 打开工程并编译一次，确保 Sparkle 在 DerivedData 中。 |
| 公证失败 | 检查 Apple ID、专用密码、`xisper-notarize` 是否仍有效。 |
| 签名报 Invalid trust settings | 按「一次性准备」第 8 条处理证书信任。 |
| wrangler / R2 上传失败 | `npx wrangler whoami`，必要时重新 `wrangler login`。 |
