# 邮箱接入配置

仅生产模式提供真实邮箱接入。演示模式会拒绝真实账号授权与添加。以下配置需由账号持有人或获批准的管理员完成，切勿在聊天、日志或 issue 中粘贴凭据。

## 系统内配置（v0.2.0）

管理员登录后可在“系统 OAuth 设置”中管理三组应用配置。优先级、密钥留空/清除/恢复语义、已有账号影响和升级备份要求见 [升级说明](OAUTH_SETTINGS_UPGRADE.md)。以下环境变量仍兼容；存在数据库覆盖时以该提供商整组数据库配置为准。填写完整不代表提供商已验证通过。

## Gmail

Google Cloud 中启用 Gmail API、配置 OAuth consent，并建立 Web application 客户端。回调地址必须精确为服务端 HTTPS 地址，例如：

`https://mail.example.com/api/v1/oauth/GMAIL/callback`

配置环境变量：

```text
MAIL_OAUTH_GMAIL_CLIENT_ID
MAIL_OAUTH_GMAIL_CLIENT_SECRET
MAIL_OAUTH_GMAIL_REDIRECT_URI
```

当前使用 `gmail.modify`，需要读写、草稿与发信权限，不能仅配置只读 scope。长期运行须核对 consent 发布状态，External Testing 下邮件权限的 refresh token 通常受 7 天到期规则影响；个人用途与公开分发应用的验证要求不同。应用需实现重新授权流程，不能假设 refresh token 永不失效。

官方参考：
- https://developers.google.com/workspace/gmail/api/auth/scopes
- https://support.google.com/cloud/answer/15549945

## Outlook 个人邮箱

在 Microsoft Entra 注册允许个人 Microsoft 账号登录的应用，配置 Web HTTPS 回调地址：

`https://mail.example.com/api/v1/oauth/OUTLOOK/callback`

```text
MAIL_OAUTH_OUTLOOK_CLIENT_ID
MAIL_OAUTH_OUTLOOK_CLIENT_SECRET
MAIL_OAUTH_OUTLOOK_REDIRECT_URI
MAIL_OAUTH_OUTLOOK_TENANT=consumers
```

使用委托权限 `Mail.ReadWrite`、`Mail.Send`、`User.Read`、`offline_access`。不要授予全租户应用级邮箱访问权。

## Microsoft E3 Exchange Online

使用组织批准的 Entra 应用及其租户；默认登录入口可使用 organizations，推荐填具体租户 ID：

```text
MAIL_OAUTH_EXCHANGE_CLIENT_ID
MAIL_OAUTH_EXCHANGE_CLIENT_SECRET
MAIL_OAUTH_EXCHANGE_REDIRECT_URI=https://mail.example.com/api/v1/oauth/EXCHANGE/callback
MAIL_OAUTH_EXCHANGE_TENANT=你的租户ID
```

E3 订阅不自动授予创建应用、用户同意、管理员同意或个人云服务器存放企业邮件的权限。遇到条件访问、设备合规或组织策略限制，需要管理员批准，不能通过降低租户安全设置解决。

Graph 官方参考：
- https://learn.microsoft.com/en-us/graph/permissions-reference
- https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/manage-app-consent-policies

## QQ 与 163

在网页版邮箱设置中启用 IMAP/SMTP 并生成客户端授权码，然后在本应用设置中选择 QQ 或 163。密码字段填写授权码，不是日常网页登录密码。

- QQ 固定使用 imap.qq.com:993、smtp.qq.com:465，TLS
- 163 固定使用 imap.163.com:993、smtp.163.com:465，TLS

检查历史收取范围、网页安全验证、授权码有效性以及云服务器出站端口。应用不会跳过 TLS 证书校验，也不会自动降级明文认证。目录识别与 MOVE 能力存在账号差异，必须在真实账号中验收。

## Compose 环境变量

`.env` 文件本身不会让所有变量自动进入容器。生产 Compose 已列出的 OAuth 环境变量才会传递给应用；添加其他配置时也要同步 Compose environment。不要把示例 client secret 当作真实值。

## 真实账号验收清单

- 授权后确认显示正确账号，退出当前窗口不会暴露 token
- 手动同步及后台刷新可得到新测试邮件
- 打开详情、下载附件不会意外改为已读
- 已读与星标能在提供商网页版看到一致结果
- 移动/归档后再次读取和操作同一封邮件仍然正确
- 发信只发给你明确批准的测试收件人，检查外部实际结果与已发送副本
- 撤销授权后只影响对应账号，并能给出可操作提示
- 已知初版限制全部可接受，再逐步加入日常邮箱
