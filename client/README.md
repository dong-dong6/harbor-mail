# 泊信 / Harbor Mail — Flutter client

中文、自托管多账户邮件客户端的 v0.1 实现。所有邮件操作都通过后端 `/api/v1`；客户端不保存服务商凭证，也不使用浏览器 localStorage 存储登录令牌。

## 启动

先启动仓库后端，然后：

```sh
flutter pub get
flutter run -d chrome --dart-define=API_BASE=http://127.0.0.1:8080/api/v1
```

建议 Web 发布使用同源：`flutter build web --release --no-web-resources-cdn`，将 `build/web` 交给仓库启动脚本提供静态服务。原生调试需要 `--dart-define=API_BASE=https://your-server.example/api/v1`。生产环境必须使用 HTTPS。Web 跨源运行还需后端配置对应 CORS，默认同源运行无需 CORS。

演示登录信息由仓库后端说明提供。演示数据为合成邮件，发送不会投递到真实邮箱。真实账户接入与演示状态分开显示。

## 验证

```sh
flutter analyze
flutter test
flutter build web --release --no-web-resources-cdn
```

`api_test.dart` 检查内存令牌、授权失效、命令幂等键与错误解码；`widget_test.dart` 使用确定性 HTTP MockClient 检查桌面登录/阅读/撰写与手机布局，测试不会连接服务商或发送邮件。

## 首版功能

- 桌面三栏、窄屏抽屉与列表/详情切换，Ctrl+N 写邮件
- 统一收件箱、按账户、文件夹、未读筛选、近期索引搜索、游标分页
- 安全纯文本正文、附件下载；显式已读/星标/归档/废纸篓/恢复命令
- 手动同步、30 秒刷新；命令排队结果可见
- 草稿保存与继续编辑、回复/转发、收件人与抄送、上传附件、发送确认
- 发件状态窗口每 3 秒更新，UNKNOWN 明确提示不可盲目重发
- OAuth 配置状态与外部浏览器授权、QQ/163 授权码接入
- 空态、错误重试、请求中禁用重复提交、会话退出

## 明确限制

- 没有离线缓存、离线变更重放、后台推送或完整历史保证
- HTML 不执行，不加载外部图片；只读纯文本 MIME 部分
- 草稿需手动保存；关闭、返回或 Escape 时会确认是否放弃未保存更改；忙碌或提交结果待核实时禁止隐式关闭
- 发送请求网络结果不明时本窗口停止再次发送，需通过明确的“关闭并查看发件状态”按钮核实结果
- 非 Web 平台目录只是 Flutter 工程脚手架，尚未在 Windows/macOS/iOS/Android 上编译、签名和验证
- Linux 原生构建也取决于系统 GTK/Clang/CMake 工具链，不等于已验收原生分发
- 真实服务商账号验收需用户明确授权和服务器 OAuth/IMAP 配置

## 真实客户端 HTTP 契约冒烟

`dart run tool/live_api_smoke.dart http://127.0.0.1:8080/api/v1`

此脚本使用应用实际 `MailApi` 与 Dart HTTP 客户端，只允许 loopback 地址，并在任何登录/写入前要求公开 health 明确标记 `demoMode: true`。登录后再次检查能力和合成数据覆盖标记。测试收件箱/详情、草稿、附件字节和版本、发送幂等性、本地合成发件副本与退出撤销。默认使用后端公开的演示凭据；可用 `MAIL_DEMO_USER`/`MAIL_DEMO_PASSWORD` 指定演示登录。严禁用于真实账号验收。

`compose_guard_test.dart` 覆盖关闭按钮、返回和 Escape 的未保存确认、取消后保留文本、忙碌期间禁止关闭，以及结果待核实后的禁止重发与明确状态入口。测试不自动保存用户草稿。
