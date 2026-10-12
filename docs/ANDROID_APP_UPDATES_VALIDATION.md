# Android App 内更新：开发交付与验收

## 状态与范围

此源码快照基于已发布 `c074f282e48e124cf0155ce81bf6d70091113afd`（v0.3.0，Android versionCode 6）。这是尚未发布的开发改动；此独立更新模块原先没有推送、部署、递增版本、创建或保存签名密钥，也没有修改真实账号配置。现有版本号不代表本功能已经在服务器或手机上线。

Android App 的“账户与设置”新增“应用更新”：手动检查、展示本机/服务器版本与更新说明、下载进度、取消和重试、下载后主动点击安装。Android 系统安装器要求用户确认；没有静默安装。更新来源是当前已配对服务器的 HTTPS 同源固定路径，不携带邮件会话令牌。

## 安全边界

- 按 Android versionCode 比较，不按版本名称排序；拒绝降级、同码异名、不同包和不同签名。
- 服务器 metadata 有 64 KiB 上限；可选纯文本更新说明最多 4,000 Unicode 码点。旧 schemaVersion 1 manifest 缺少说明仍可使用。
- manifest 和 APK 都不跟随重定向。下载大小最多 256 MiB，校验实际字节数和 SHA-256，下载有连接、读取及总时限。
- SHA-256/manifest 用于文件一致性；真正的签名信任锚是本机已安装 App 的当前单一签名证书。APK 还经过官方 apksig 完整密码学验签及 Android 包信息检查；交给安装器前再次校验。
- FileProvider 非导出，仅暴露专用更新缓存子目录；只给系统安装器临时只读 URI 权限，不使用外部公共存储。
- Android 未允许安装来源时，只提示用户主动前往系统设置。返回后仍须再次点击安装；不自动改变权限、不自动继续安装。
- 原生单操作互斥，取消等待下载停止并清理未完成文件；页面关闭/服务器变更会取消安装前的校验，阻止旧结果回写和旧安装器意外弹出。系统安装器已接收的文件保留，后续启动按 24 小时策略清理。
- 检查、失败、取消均不删除账号或配置；安装成功与否以系统结果为准。正常同包同签名升级保留本地数据，现有内存会话仍可能需要重新登录。

## 已验证

- Flutter 静态分析通过；全套 327 项 Flutter 测试通过，33 项更新/下载专项用例覆盖请求/响应体超时、实际超限流、不同签名、旧 metadata、服务器版本错配、窄屏长说明、重复点击、取消重试、迟到回调、切换服务器、关闭页面、权限设置交接及安装器失败恢复。
- Flutter Web release 构建通过，原有 Web 下载入口保持可用。
- 后端 H2 全套 379 项测试通过，0 失败/错误/跳过，包括 10 项 Android 下载单元/HTTP 测试。
- Android 发布脚本 9 项 Python 测试和 Web 发布脚本 1 项测试通过；shell 语法、版本一致性和 diff whitespace 检查通过。
- 原生纯 Java 更新策略 72 项检查通过。该检查已接入 Android CI 构建脚本。
- 新增 Java 桥接使用真实 Android API 类、Flutter engine、官方 AndroidX/apksig 依赖编译通过。MainActivity 已用 Kotlin 2.4.0、target 17 编译通过；详情见 `client/android/UPDATES.md`。
- 官方 apksig 9.1.0 对已发布的真实 v0.3.0 APK 在 API 24 和 API 36 规则下验签通过，且唯一证书为 `678f55ac9835ca05d8a2adc40affca397ac48781796973d98ee1a33753233cb8`。这是旧 APK 的验证器兼容性检查，不是新 APK 构建证明。

## 尚未验证，不能视为已发布

当前云环境没有完整 Android SDK/NDK 或 adb，未生成包含新代码的 APK，未运行完整 Android Gradle/D8 打包，也没有进行真机或模拟器系统安装/未知来源权限验收。Java/Kotlin 编译、Flutter 测试和旧 APK 验签不能代替这些检查。

还需在获准的完整 Android 构建环境中验证：新 APK 构建；相同临时签名下连续两个递增版本的覆盖升级；Android 24 与 26+（含当前版本）系统安装器；权限拒绝/返回/取消/再次安装；网络中断、磁盘不足、App 重启后的文件生命周期；升级后已保存服务器配置仍在。不得自动接受未授权 SDK 协议或安装权限。

## 当前版本的签名阻塞与最小发布步骤

现有 CI 使用全新 runner 默认生成的临时 debug keystore，无持久化签名缓存。当前应用包名为 `dev.harbor.harbor_mail.dev`。不同 CI 构建通常具有不同私钥/证书，不能保留同包本地数据直接覆盖升级；本功能会阻止这种更新。单纯复制公开证书指纹不能恢复签名私钥。

1. 先由用户决定并批准长期签名/分发通道，并通过安全流程配置已有签名凭据。本次没有创建固定密钥或改变生产信任。
2. 若当前已安装 APK 的私钥仍可合法取得，使用同一签名并提高 versionCode 才能原地升级。若临时私钥已经丢失，就不存在让不同签名 APK 无损覆盖此包的技术捷径。保留现有 App；需另行确认迁移方案，例如独立正式包重新配对，不能默认卸载现有 App。
3. 正式包/正式签名通道还需单独审查 manifest 的包名及 classification 白名单。本实现仅针对现有 `.dev` 下载通道，不悄悄开放生产信任。
4. 用户明确授权发布后，提高 versionCode、更新说明，运行完整 CI/设备验收，再一起部署对应服务器 manifest 与 APK。版本号及签名都相容时，手机即可在 App 内主动下载并调用系统完成更新。

## 本地复核命令

```sh
cd client
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
flutter build web --release --no-pub --no-web-resources-cdn
cd ..
bash client/android/tests/run-policy-tests.sh
python3 scripts/test-prepare-android-download.py
python3 scripts/test-prepare-web-assets.py
mvn -B -f server/pom.xml test
python3 scripts/check-version.py
```

具体工具版本和 native 编译证据以原生验收记录为准。完整 Android 构建需预先配置官方 SDK/NDK 和已接受的许可，使用 `scripts/build-android-download.sh`，不能把本地源码工作区冒充已发布 CI commit。

## v0.3.1 集成说明

更新模块已合入 v0.3.1+7 缺陷修复源码。新增未交付下载结果超时/取消清理竞态修复，原生策略检查共 82 项。集成状态以 ANDROID_FIXES_v0.3.1.md 为准；旧 APK 的验签不代表新 APK 已构建。
