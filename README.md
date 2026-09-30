# 个人云端邮箱客户端 v0.1

个人自托管邮箱客户端的第一版实现：Java 21 / Spring Boot 服务端统一连接邮箱，Flutter 客户端仅访问自己的服务端。项目包含明确隔离的合成演示模式，以及 Gmail、Outlook、Microsoft 365 E3、QQ、163 的接入实现。

**这不是已接入你真实邮箱的成品部署。** 真实账号需要你在自己的环境配置 OAuth 应用或客户端授权码。当前交付的测试使用合成数据和本地协议模拟服务器，不会向真实收件人发送邮件。

## 当前仓库交付状态

完整源码、配置、文档与可运行 JAR 均包含在 Releases 的 `mail-client-v0.1.0.zip` 中。源码目录尚未展开到此仓库的 main 分支；请下载 Release 中的完整 ZIP，不要使用 GitHub 自动生成的 Source code 压缩包。以下源码构建与运行命令均在完整 ZIP 解压后的项目目录执行。

## 最快体验

GitHub Release 完整包为 `mail-client-v0.1.0.zip`：只需下载并解压这一个 ZIP，无需合并分包。GitHub 自动生成的 Source code 压缩包只包含源码，不包含集成 JAR，需要自行构建。

如果使用聊天附件的分包交付，则包含一个源码包和四个运行包。将五个 ZIP 全部解压到同一个目录，让它们合并到同一个 `mail-client-v0.1.0` 文件夹中。Windows 运行 `scripts/run-demo.bat`，会先自动合并并验证 JAR 再启动；Linux/macOS 使用 `bash scripts/run-demo.sh`。分包只用于满足附件大小限制，程序内容不变。Windows 批处理脚本已提供，但未在 Windows 系统执行验收。

交付包的 `dist/mail-client.jar` 同时包含服务端和编译后的 Flutter Web。

1. 安装 Java 21
2. 解压交付包，在根目录执行：

```bash
java -jar dist/mail-client.jar --spring.profiles.active=demo
```

3. 浏览器访问 `http://127.0.0.1:8080`
4. 演示用户名 `demo`，密码 `demo-local-only`

演示服务强制仅监听本机 127.0.0.1，数据保存在启动目录下的 `data/demo`。演示账号、邮件和收发全部为本地合成数据；禁止用于公网或真实邮件。登录页面和应用内均应明确显示演示状态。Linux/macOS 可使用 `scripts/run-demo.sh`。

## 初版功能范围

- 登录、退出、短期会话令牌和登录限流
- 五类邮箱接入入口；未配置 OAuth 的入口明确不可用
- 统一收件箱、系统文件夹、搜索、分页、邮件详情
- 已读、星标、归档、移至废纸篓与恢复等操作，受上游能力限制
- 纯文本安全阅读，HTML 邮件转为文本，不执行邮件脚本或加载远程图片
- 草稿保存及版本冲突检查、回复/转发编辑、附件上传和下载
- 持久化发件任务、请求幂等、结果不明状态，防止盲目自动重发
- Gmail API、Microsoft Graph、QQ/163 固定 TLS IMAP/SMTP 适配器
- Flutter Web 成品构建及六个平台的源工程

具体已通过的检查和已知限制见 [测试报告](docs/TEST_REPORT.md) 与 [初版边界](docs/KNOWN_LIMITATIONS.md)。源码中存在一个平台工程，不代表已编译、签名或真机验证该平台。

## 仓库结构

```text
server/       Spring Boot API、持久任务、OAuth、邮箱适配器和 JUnit 测试
client/       Flutter UI、HTTP 客户端、平台工程和测试
docs/         API 契约、邮箱配置、测试报告、已知限制
scripts/      构建、演示启动、黑盒测试和打包
dist/         可直接运行的集成 JAR
Dockerfile    集成 JAR 的非 root Java 运行镜像
docker-compose.yml  PostgreSQL + 应用；端口只发布到主机回环地址
```

开发工具、依赖缓存、测试数据库、环境密钥与日志不属于交付源码。

## 从源码构建

需要完整 JDK 21、Maven 3.9+、Flutter 3.47.5 / Dart 3.13.4。SDK 可放 PATH；本环境开发工具位于 `tools/`，此目录不会打包。

```bash
bash scripts/build.sh
```

脚本执行 Flutter analyze、Flutter tests、Web release build、Maven verify，再生成集成 JAR。Web 字体与 CanvasKit 均本地打包，不依赖运行时字体 CDN。网络代理环境可通过 `MAVEN_SETTINGS` 指定自己的 Maven 配置；脚本也支持当前 `HTTPS_PROXY`，生成的配置仅在本地工具目录保存。

原生端可设置 `--dart-define=API_BASE=https://你的服务端地址/api/v1`。API_BASE 包含 `/api/v1` 前缀，不将邮箱提供商地址传入客户端。Windows、macOS、iOS、Android、Linux 的构建工具与签名条件不同；参见 [客户端说明](client/README.md)。

## 使用真实邮箱的部署前提

1. 使用自己的域名、HTTPS 入口及可访问所有目标邮箱服务的服务器
2. 确認 E3 租户允许该应用，并允许企业邮件在这台服务器上处理或缓存
3. 配置唯一管理员密码、随机 32 字节凭据加密密钥、PostgreSQL 密码
4. 完成供应商 OAuth 应用登记或客户端授权码获取
5. 先用你明确允许测试的邮箱验证收发，不直接导入全部历史邮件
6. 先阅读限制和备份要求，再用于日常邮件

```bash
cp .env.example .env
# 编辑 .env，填写所有空值。不要把密码或密钥提交到 Git。
# 随机密钥示例：openssl rand -base64 32
docker compose up -d --build
```

构建 Docker 镜像前必须已有 `dist/mail-client.jar`，交付包已包含；从源码启动则先执行构建脚本。Compose 不发布数据库端口，HTTP 仅发布至主机 `127.0.0.1:8080`，应由主机 HTTPS 反向代理访问。不要把 HTTP 直接改为公网监听来绕过 TLS 配置。

生产环境必须保留 `.env` 中的加密密钥。更换密钥但未迁移凭据会使已保存的邮箱授权无法解密。备份数据库、应用数据卷和密钥，密钥与数据副本分开保护。首次正式使用前应做恢复演练。

## 安全注意

- 本服务运行时可以读取邮件，不是服务器不可见的端到端加密
- Web 登录令牌只放内存，刷新页面可能需要重新登录；未宣称离线会话或长期安全令牌存储完成
- 生产端没有公开注册，账号与邮箱接入只由唯一管理员使用
- 不开放任意 IMAP/SMTP 主机输入，减少代理被用作内网探测的风险
- 不将密钥、授权码、OAuth token、邮件正文放入日志或诊断包
- 不把“服务商已接受发送”称为“收件人已收到”
- 发送结果 UNKNOWN 时先核对原邮箱，不能直接再次点击重发

## 测试

```bash
# 服务启动并明确处于 demo 模式后：
python3 scripts/smoke-demo.py --url http://127.0.0.1:8080
```

黑盒测试遇到非演示服务会立即拒绝执行，避免误操作真实邮箱。各测试的最终结果见 `docs/TEST_REPORT.md`。

## 初版与完整方案的关系

这是完整开发方案的首个可运行版本。全量历史、可靠增量游标与删除校准、系统推送、完整离线缓存和原生分发签名是独立后续工作，不能把当前版本称为六端生产级邮件产品。接入代码的模拟测试通过也不等于真实 Google/Microsoft/QQ/网易账号验收完成。

本项目未发布到公共代码仓库，未进行任何真实邮箱授权或外部投递。所有第三方依赖遵循其各自许可证；内置字体许可证见客户端 assets。
