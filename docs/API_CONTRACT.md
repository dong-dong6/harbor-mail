# Initial version API contract

Base `/api/v1`, JSON UTF-8. This is the implementation baseline; coordinate changes across owners. Single owner, multiple accounts/devices. Server normalizes all remote mail. Never place provider credentials in client responses. Demo uses synthetic local data and NEVER calls providers.

## Authentication
- GET `/health`: `{status:"UP",version:"0.1.0",demoMode:true}` public only non-sensitive status
- POST `/auth/login`: `{username,password}` -> `{accessToken,expiresAt,demoMode}`. Random opaque bearer token, server stores only hash, expiring/revocable. Flutter keeps it in memory for v0.1 (no browser localStorage). Strict password hash, rate limits; production requires environment bootstrap credentials. Demo profile loopback-only and explicit synthetic data banner; documented demo-only credentials permitted, never fallback in production.
- POST `/auth/logout`: authenticated revocation ->204
All subsequent API routes Bearer authentication. API failures `{error:{code,message,requestId}}`; upstream errors cannot expose secrets.

## Accounts and mail
- GET `/accounts`: `{items:[{id,provider,email,displayName,status,lastSyncAt,unreadCount,errorCode}]}`
- POST `/accounts/imap`: `{provider:"QQ"|"NETEASE",email,displayName,authorizationCode}` -> public account. Fixed trusted provider hosts, TLS, no arbitrary host/port in v0.1. Encrypt secret at rest; connect via explicit sync.
- POST `/accounts/{id}/sync`: ->202 `{jobId,status:"QUEUED"}`; merge duplicate jobs
- GET `/accounts/{id}/folders`: `{items:[{id,name,role,unreadCount}]}`
- GET `/messages?accountId=&folder=INBOX|SENT|TRASH|ARCHIVE|STARRED&query=&unreadOnly=false&cursor=&limit=50`: `{items:[{id,accountId,fromName,fromAddress,subject,snippet,receivedAt,isRead,isStarred,hasAttachments,revision}],nextCursor,hasMore,coverage:"DEMO"|"RECENT"|"PARTIAL"|"FULL"}`; empty accountId unified view. Query optional. Enforce max page size. Cursor pagination stable.
- GET `/messages/{id}`: above fields plus `{to:[{name,address}],cc:[{name,address}],bodyText,bodyHtml,folder,attachments:[{id,fileName,contentType,size}]}`. Server HTML sanitized; client v0.1 default plain text, no raw HTML execution. Fetch detail never marks read by itself.
- POST `/commands`, header `Idempotency-Key`, body `{type:"SET_READ"|"SET_STAR"|"TRASH"|"ARCHIVE"|"RESTORE",messageId,baseRevision,value?:boolean}` ->202 `{id,status}`
- GET `/commands/{id}`: `{id,status,errorCode,messageId}`. Demo mutation can finish immediately, real provider failure explicit. No fake provider success.
- GET `/attachments/{id}/content`: authenticated stream, safe content disposition. No arbitrary URL fetching.

## Drafts and sending
- GET `/drafts`: `{items:[{id,accountId,to,subject,bodyText,revision,updatedAt}]}`
- POST `/drafts`: `{accountId,to:[{address,name?}],cc?:[],bcc?:[],subject,bodyText,replyToMessageId?:string}` -> complete draft with id/revision
- PATCH `/drafts/{id}` same editable fields plus `revision` optimistic concurrency -> updated draft or409
- DELETE `/drafts/{id}` ->204; must not delete frozen send snapshot
- POST `/drafts/{id}/attachments` multipart field `file`: -> attachment metadata; authenticated bounded stream; max10MiB raw v0.1 plus provider total/MIME limit
- POST `/drafts/{id}/send`, Idempotency-Key, `{revision}` ->202 `{id,status:"QUEUED"}`. Server freezes snapshot and persists send intent. No network send on UI duplicate click or retry. Demo sends LOCAL synthetic message only.
- GET `/send-intents`: `{items:[{id,accountId,subject,status,createdAt,errorCode}]}`
- GET `/send-intents/{id}`: intent info. Status QUEUED/PREPARING/SUBMITTING/ACCEPTED/SENT_COPY_CONFIRMED/FAILED/UNKNOWN. Unknown outcomes NEVER blindly retried.

## Configuration and OAuth
- GET `/settings/capabilities`: `{demoMode,providers:[{provider,configured,supportsOAuth,supportsImap}],limits:{maxAttachmentBytes},features:{html:false,offlineCache:false}}`. Frontend show unsupported features honestly.
- POST `/oauth/{provider}/start` `{}` where provider GMAIL/OUTLOOK/EXCHANGE -> `{authorizationUrl}` (or actionable PROVIDER_NOT_CONFIGURED). HTTPS redirect must be configured by operator. Single-use state bound to owner and TTL. Browser system authorization popup; callback validates state, stores encrypted tokens, returns safe status page without secrets. No built-in real credentials.
- GET `/oauth/{provider}/callback` public OAuth callback only. Implement providers actual OAuth if feasible; never pretend connected without real callback.
- GET `/changes?after=...`: `{items:[{seq,type,entityId,revision}],nextCursor,hasMore}`. Need commit-order guarantee; fail410 for expired generation. Client may initially poll refreshed lists instead but document sync limitations.

## Version scope
Real Gmail/Graph/IMAP adapters must implement bounded initial/recent metadata sync, detail fetch, basic changes and send when correctly configured; tests use deterministic fake HTTP/IMAP/SMTP endpoints only. Real account acceptance remains pending user authorization. Adapter owner exposes clean DTOs to server core and coordinates integration immediately. Complete history, push subscriptions, guaranteed offline mutation replay and all native release signing can be explicitly deferred. All nonimplemented actions return honest NOT_SUPPORTED, no success-shaped stubs.

## 管理员 OAuth 应用设置（v0.2.0）

沿用单一管理员 Bearer 认证。未认证返回 401；demo 可读，所有写入返回 409 `DEMO_MODE`。不返回 `clientSecret`、密文、令牌或配置指纹。配置响应 `Cache-Control: no-store`。

`GET /settings/oauth`：

```json
{
  "demoMode": false,
  "readOnly": false,
  "items": [{
    "provider": "GMAIL",
    "source": "ENVIRONMENT",
    "revision": 0,
    "clientId": "",
    "redirectUri": "",
    "tenant": "",
    "hasClientSecret": false,
    "configured": false,
    "validationErrors": ["Client ID is required"]
  }]
}
```

实际 `items` 固定包含 `GMAIL`、`OUTLOOK`、`EXCHANGE`。`configured` 表示本地完整性/格式校验通过，绝不表示已通过提供商授权或连接测试。

`PUT /settings/oauth/{provider}`：

```json
{
  "revision": 0,
  "clientId": "application-id",
  "redirectUri": "https://mail.example.com/api/v1/oauth/GMAIL/callback",
  "tenant": "",
  "clientSecret": "",
  "clearClientSecret": false
}
```

`clientId`、`redirectUri`、`revision` 必填，允许空 ID/回调以保存不完整配置，但不可用于授权。`clientSecret` 省略或空白保留当前生效值；显式 `clearClientSecret: true` 清除密钥，不能与非空新密钥同时使用。数据库覆盖是整组配置。租户省略/空白使用该提供商默认值。拒绝未知字段、控制字符、错误类型和无效 HTTPS 回调/租户。

`POST /settings/oauth/{provider}/reset`，请求 `{"revision": 1}`：清除数据库覆盖并恢复进程环境变量，版本仍递增。

两种写入均返回更新后的单个 provider metadata。并发旧版本返回 409 `CONFIG_REVISION_CONFLICT`，不得自动覆盖新版本。未知 provider 或无效字段返回 400 `INVALID_REQUEST`。保存不会调用外部提供商验证凭据。

授权过程中应用配置改变可返回 409 `OAUTH_CONFIG_CHANGED`，须重新开始授权。已有凭据与当前应用身份不匹配时返回 `REAUTH_REQUIRED`；不会将旧 refresh token 发送到新应用。
