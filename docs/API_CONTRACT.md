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
