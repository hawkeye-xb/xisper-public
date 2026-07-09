import os

def generate_sop_md():
    content = """# 域名邮箱全免费方案 (SOP)
## —— 零成本实现“无限席位”收发体系

本方案通过 **Cloudflare Email Routing**（收件）与 **Gmail SMTP 别名借壳**（发件）的组合，彻底摆脱按席位计费的限制。

---

### 一、 核心逻辑
* **收件流：** 用户发送至 `hi@yourdomain.com` -> Cloudflare 转发 -> 你的个人 Gmail。
* **发件流：** 你在 Gmail 点击“回复” -> Gmail 服务器验证权限 -> 以 `hi@yourdomain.com` 身份发出。

---

### 二、 准备工作
1.  **域名：** 已托管在 Cloudflare。
2.  **邮箱：** 一个开启了“两步验证”的个人 Gmail 账号。

---

### 三、 执行步骤 (SOP)

#### 第一阶段：Cloudflare 端的收信配置
1.  登录 Cloudflare，进入目标域名控制面板。
2.  导航至 **Email** -> **Email Routing**。
3.  **添加目标地址：** 在 "Destination addresses" 中添加你的个人 Gmail 地址并完成验证。
4.  **配置路由规则：** * 在 "Routing rules" 中点击 "Create address"。
    * 设置前缀（如 `support`, `contact` 或 `*` 通配符）。
    * 选择转发到刚才验证的 Gmail。

#### 第二阶段：Google 账号的安全授权
1.  访问 [Google 账号设置](https://myaccount.google.com/)。
2.  进入 **安全性 (Security)** 选项卡。
3.  确保 **两步验证 (2-Step Verification)** 已开启。
4.  在搜索框搜索 **"App Passwords" (应用专用密码)**。
5.  创建一个新的应用密码，名称建议设为 `Cloudflare SMTP`。
6.  **记下弹出的 16 位字符密码**（这是后续发信的关键凭证）。

#### 第三阶段：Gmail 端的发信设置 (借壳)
1.  打开 [Gmail 网页版](https://mail.google.com/)，进入 **设置 -> 查看所有设置**。
2.  点击 **账号和导入 (Accounts and Import)**。
3.  在 **用这个地址发送邮件 (Send mail as)** 栏目点击 **添加其他电子邮件地址**。
4.  **配置窗口：**
    * **姓名：** 填写你想显示的对外名称（如：Shalamira）。
    * **电子邮件地址：** 填写你的完整域名邮箱（如 `support@yourdomain.com`）。
    * **取消勾选** “视作别名 (Treat as an alias)”。
5.  **SMTP 服务器设置：**
    * **SMTP 服务器：** `smtp.gmail.com`
    * **端口：** `587`
    * **用户名：** 你的**完整个人 Gmail 地址**。
    * **密码：** 填入刚才生成的 **16 位应用专用密码**。
    * **连接方式：** 选用 TLS 链接。
6.  完成验证（去 Gmail 收件箱查收验证码并填入）。

#### 第四阶段：优化邮件到达率 (DNS 配置)
*为了防止邮件被识别为垃圾邮件，必须更新 Cloudflare 的 DNS 记录。*

1.  回到 Cloudflare **DNS** 设置。
2.  找到自动生成的 **SPF 记录** (TXT 类型，通常以 `v=spf1` 开头)。
3.  将其内容修改为包含 Google 的发信服务器：
    `v=spf1 include:_spf.mx.cloudflare.net include:_spf.google.com ~all`
4.  保存。

---

### 四、 进阶建议
1.  **多前缀支持：** 你可以重复“第三阶段”，在 Gmail 中添加多个域名邮箱别名，回信时自由切换。
2.  **系统发信：** 如果产品（如 Web 应用）需要自动发送验证码，建议单独使用 **Resend** 或 **Amazon SES** 的 API 接入，以保护个人 Gmail 的发信配额。
3.  **回复偏好：** 在 Gmail 设置中，建议选择 **“从收到邮件的地址进行回复”**，这样系统会自动帮你选好对应的域名别名。

---

*“效率生活，是为了更好地发呆。” —— 祝配置顺利！*
"""
    filename = "domain_email_sop_v1.md"
    with open(filename, "w", encoding="utf-8") as f:
        f.write(content)
    return filename

file_path = generate_sop_md()
print(f"File generated: {file_path}")