# 个人云端邮箱客户端 v0.3.0

个人自托管邮箱客户端的第一版实现：Java 21 / Spring Boot 服务端统一连接邮箱，Flutter 客户端仅访问自己的服务端。项目包含明确隔离的合成演示模式，以及 Gmail、Outlook、Microsoft 365 E3、QQ、163 的接入实现。

**这不是已接入你真实邮箱的成品部署。** 真实账号需要你在自己的环境配置 OAuth 应用或客户端授权码。当前交付的测试使用合成数据和本地协议模拟服务器，不会向真实收件人发送邮件。

## v0.3.0 设备登录与 Android 下载

- 网页生成两分钟单次配对二维码；App 扫描后自动填写服务地址及账户，由网页核对校验码并输入 owner 密码确认完整权限。独立设备会话可即时撤销。
- Android 指纹/设备凭据和 Windows Hello/PIN 可为当前内存会话启用本机锁；锁屏退出及慢请求具会话隔离，已解锁会话可明确关闭本机锁。
- 标准 WebAuthn 通行密钥注册、登录和删除；系统选择可用认证器，包括平台通行密钥与兼容安全密钥。注册和删除须 owner 密码确认。
- CI 构建本项目 Android 开发测试 APK，网页显示实际版本、大小、SHA-256 及下载。`.dev` 安装包使用临时测试签名，不承诺跨构建覆盖升级；正式稳定签名另需配置。
- 登录令牌仍只在内存，最多八小时；服务器地址与账户显示名可保存在原生客户端，不保存密码或 token。真实设备相机与系统身份验证需要在目标设备验收，合成测试不能替代。
- 配对部署需要规范 HTTPS 的 `MAIL_ALLOWED_ORIGIN`；Android 原生 Passkey 还需要签名身份、服务端信任源与站点关联配置。详见 [设备登录](docs/DEVICE_PAIRING.md)、[通行密钥](docs/PASSKEY_CONTRACT.md)、[APK 下载](docs/ANDROID_DOWNLOADS.md)。

## v0.2.3 账户管理、阅读与安全更新

- 账户与设置直接切换主内容页面，默认显示已连接邮箱；支持修改本地名称和带明确后果提示的断开连接。添加邮箱和系统 OAuth 设置是独立页面。
- 阅读页显示主题、发件人与收件详情；打开邮件重置阅读位置。回复和转发编辑器位于正文下方，保留未保存内容和不确定发送状态的离开保护。
- 邮件图片默认阻止，用户选择加载后仅通过鉴权、绑定当前邮件的受限图片代理获取；浏览器不回退直连图片原站。
- 邮件和设置拥有可复制的 hash URL，支持浏览器前进/后退；刷新后需重新登录，不持久化登录令牌。
- 构建资源采用精确清单、gzip 和 ETag 重新验证；API 与 OAuth 完成页保持 no-store，保留完整中文字体。
- 修复非规范请求路径与处理器路径解释不一致造成的鉴权缺口；编码、矩阵参数、点路径等歧义形式在进入处理器前拒绝。
- V5 使用独立附件归属表，保留旧附件表五列。断开连接只删除 Harbor 的本地数据，不删除服务商邮件或撤销服务商授权。升级前仍须停写并验证数据库备份；恢复备份会丢失备份后的写入。

## v0.2.2 邮件阅读与多账户修复

- 恢复 HTML 邮件表格、行内样式和可读链接；隔离执行环境、默认阻止远程图片，支持单封开启和纯文本切换。
- 自动升级旧正文缓存，保留 Gmail/Outlook/IMAP 的 HTML 与纯文本表示；元数据同步不再清空已取正文。
- OAuth 完成后返回发起授权的邮箱页，相关性校验后刷新账户；原页不可用时提供固定安全回退页。
- 左上方常驻多邮箱入口，手机横向账户栏、紧凑列表和更清楚的名称/地址层级。
- 安全与验收边界见 [合并测试报告](docs/COMBINED_FIX_TEST_REPORT.md)。

## v0.2.1 界面与交互更新

- 浅蓝灰主框架、全宽紧凑邮件列表；点击邮件后进入阅读视图，返回恢复列表滚动位置。
- 左上方常驻邮箱列表，手机端横向账户切换栏；未接入邮箱时显示引导，写信按钮进入账户连接。
- 全部、未读、星标筛选；账户标记、已发送收件人和当天时间。
- 静默刷新保留已加载的分页范围；导航、搜索和返回取消过期详情展示，避免慢请求覆盖当前页面。
- 新邮件默认使用当前账户；手机阅读/写信留白调整，账户设置操作固定可见，OAuth 等待提示使用中性色。
- 保留发送确认、未知发送结果禁止盲目重试、OAuth 安全边界；没有增加附件删除或真实邮箱验收范围。

## v0.2.0 新增

管理员可在系统内填写 Google、Outlook 和 Microsoft 365 E3 的 OAuth Client ID、密钥、HTTPS 回调与租户，无需为每次应用配置修改环境变量。密钥加密保存且不回传，支持留空保留、显式清除和恢复环境变量。演示模式只读。详见 [OAuth 设置与升级说明](docs/OAUTH_SETTINGS_UPGRADE.md)。

配置完整不等于真实授权验证通过；应用或租户改变后，已有邮箱可能需要重新授权。升级必须保留原 `MAIL_ENCRYPTION_KEY` 和数据库。

## 最快体验

本版完整更新包为 `mail-client-v0.3.0.zip`：只需下载并解压这一个 ZIP，无需合并分包。本次交付不会自动发布 GitHub Release；旧 `v0.1.0` 包不含系统内 OAuth 设置。GitHub 自动生成的 Source code 压缩包只包含源码，不包含集成 JAR，需要自行构建。

Windows 可运行 `scripts/run-demo.bat`，Linux/macOS 使用 `bash scripts/run-demo.sh`。本版完整包已包含集成 JAR，不需要分包合并。Windows 批处理脚本已提供，但未在 Windows 系统执行验收。

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
- Web 版隔离 HTML 邮件阅读，保留表格与行内样式；默认阻止远程图片，可对单封邮件开启，保留纯文本切换。详见 [HTML 阅读安全边界](docs/HTML_MAIL_READING.md)
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

## GitHub Actions 自动构建

`.github/workflows/build.yml` 在每次分支 push、Pull Request 和手动 **Actions → Build and release → Run workflow** 时运行：

1. 使用 Ubuntu 24.04、Java 21、Flutter 3.47.5（官方 SDK + SHA-256 校验）
2. Flutter analyze / test、Web release 构建，随后 Maven verify（H2）
3. 另外以 PostgreSQL 17 服务执行后端测试
4. 启动集成 JAR，验证 Web 入口并运行仅针对合成演示数据的黑盒测试
5. 生成完整运行 ZIP 和 `SHA256SUMS`，上传至本次运行页面的 **Artifacts → mail-client-提交SHA**，保留 14 天；测试报告保留 7 天

下载 Actions artifact 并解压外层归档后，里面的 `mail-client-v版本.zip` 就是包含源码与 `dist/mail-client.jar` 的完整包，不需本地安装 Flutter/Maven。运行只需 Java 21。可用 `sha256sum -c SHA256SUMS` 校验完整包。

发布新版本时，先同步修改 `server/pom.xml` 与 `client/pubspec.yaml` 的版本号，再推送对应 `vX.Y.Z` 标签。例如版本号改为 `0.1.1` 后：

```bash
git tag v0.1.1
git push origin v0.1.1
```

只有 **push 版本标签** 且所有构建与测试成功才会创建 GitHub Release，附上完整 ZIP 和校验文件。手动运行与 PR 均不会发布。版本不匹配会提前失败；已有 Release 不会被覆盖，请使用新版本标签。普通构建只有 `contents: read`，发布作业单独使用 `contents: write`；不需要设置个人访问令牌、邮箱凭据或生产密钥，也不会自动部署服务。

此流水线生成 Flutter Web + Java 集成运行包，尚不包含 Android/iOS/桌面原生安装包与签名。GitHub 托管 runner 需要能下载 Maven、Flutter、Pub 依赖和 PostgreSQL 镜像；首次构建用时取决于依赖下载速度。

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

本项目未进行任何真实邮箱授权或外部投递。所有第三方依赖遵循其各自许可证；内置字体许可证见客户端 assets。
