# v0.1 测试与交付验收

日期：2026-09-30。验证对象为交付包中的集成 JAR 和对应源码。所有邮箱与收件人均为合成测试数据，未授权或访问任何真实邮箱，也未向外部收件人投递。

## 已通过

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| Flutter 静态分析 | 通过 | 无分析问题 |
| Flutter 测试 | 10 项通过 | API、桌面/手机交互、合成截图、未保存草稿保护、发送不明状态保护 |
| Flutter Web release | 构建成功 | 本地中文字体和 CanvasKit，不依赖运行时字体 CDN |
| Java Maven verify | 47 项通过 | 23 个真实本地 HTTP 测试、5 个启动安全测试、19 个提供商模拟协议测试 |
| H2 数据库 | 同一组47项通过 | 演示/本地测试模式 |
| PostgreSQL 17.11 | 同一组47项通过 | 真实 PostgreSQL 进程，Flyway V1–V3 |
| Python 黑盒验收 | 9 组通过 | 最终集成 JAR，登录、邮件、草稿、幂等及本地模拟发送 |
| 实际 Dart MailApi 联调 | 6 组通过 | 使用真实 HTTP 客户端访问最终 JAR，非 MockClient |
| 集成静态资源 | 通过 | JAR 中首页及 Flutter bootstrap 匿名可加载，API仍需认证 |
| 防嵌入响应头 | 通过 | DENY/frame-ancestors，未把 API 的 default-src none 错用于 Flutter |
| Compose 配置 | 静态检查通过 | YAML可解析，数据库不发布端口，应用仅发布至主机回环地址 |

H2与PostgreSQL复用了相同47项测试，不把它们称作94个不同测试。机器可读摘要、版本及 JAR SHA-256 位于 BUILD_INFO.json。

## 核心验收覆盖

- 未登录不能读取邮箱，错误密码拒绝，退出后旧 token 失效
- 生产缺失凭据、弱密码、已公开的演示密钥等情况拒绝启动；演示只允许本机监听
- 稳定分页、搜索及非隐式已读的正文读取
- 相同幂等键重复提交只创建一个任务；不同内容复用同键拒绝
- 并发提交、草稿旧版本冲突、附件大小限制及上传下载
- 发信冻结内容后删除/修改原草稿，不破坏发件快照
- 发送中断进入 UNKNOWN，不自动重发；PREPARING 阶段可恢复
- QQ/163 适配的 UIDVALIDITY 校验和 MOVE 后新 UID 映射
- SMTP RCPT拒绝与最终DATA响应丢失区分；Bcc在投递信封中但不出现在DATA头
- Gmail标签动作、Graph ImmutableId、OAuth PKCE与刷新token保留
- 关闭、返回或Escape时提示未保存草稿；取消关闭保留内容，不偷偷自动保存
- 正在请求或结果不明时阻止重复发送；提供明确发件状态入口

## 最终集成 JAR 黑盒结果

Python验收9组：演示模式安全门槛、鉴权拒绝、登录与账户、目录列表与正文、分页不重复、命令幂等、草稿版本、模拟发送及重复提交防护、变更接口及注销。

Dart验收6组：演示健康检查、内存Bearer登录、账号/列表/正文、草稿/附件上传下载/版本、重复发送同一幂等键只产生一个已确认本地副本、退出与令牌清理。验证工具遇到非演示服务立即停止。

所有发送验证仅在 demo 模式保存本地合成已发送记录，不能由此推导真实邮件已成功投递。

## 界面验证的边界

已检查 Flutter 1440像素桌面与390像素手机布局的渲染和交互，交付的预览图片是合成测试数据的 Flutter 渲染结果。

云端浏览器访问本机应用地址时返回 ERR_BLOCKED_BY_CLIENT，因此未完成真实浏览器点击路径的端到端验收；没有绕过访问限制。真实 HTTP API联调和Web构建通过，不等同于浏览器端到端测试通过。

## 未执行或尚未完成

- Gmail、Outlook、E3、QQ、163真实账号授权与供应商真实收发验收
- Windows/macOS/Linux/Android/iOS原生release构建、签名、安装和真机验收
- Docker镜像及Compose实际运行，当前执行环境没有Docker运行时
- 完整历史与增量同步、上游删除/外部移动校准、持久离线重放、系统推送
- 十万封邮件压力测试、长期运行、跨版本恢复演练、第三方安全审计

不应把初版部署为已完成上述验收的生产级邮件产品。请结合 KNOWN_LIMITATIONS.md 评估是否适合接入日常邮箱。

## 已知非阻断提示

Flyway对演示使用的H2版本给出其已验证版本范围提示。本轮H2迁移和测试通过；正式存储目标为已实际测试的PostgreSQL。更换H2或Flyway版本仍需重新验证迁移。

## 复现

```bash
bash scripts/build.sh
bash scripts/run-demo.sh
# 另一个本机终端执行：
python3 scripts/smoke-demo.py
# 在client目录执行，需Dart/Flutter环境：
dart run tool/live_api_smoke.dart http://127.0.0.1:8080/api/v1
```

PostgreSQL测试会清空指定测试库中的合成数据，必须使用隔离测试库，严禁指向真实邮箱库。详细参数见 server/README.md。
