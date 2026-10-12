# 第三方组件说明

本项目使用Spring Boot、Spring Framework、PostgreSQL JDBC、Flyway、H2、Jackson、Eclipse Angus Mail、jsoup、Flutter、Dart和Flutter依赖包。精确版本见server/pom.xml、client/pubspec.lock和BUILD_INFO.json；许可证以各依赖发行包的原文为准。

中文字体为Noto Sans SC，许可证随client/assets/fonts一并交付。Flutter Web构建产物包含生成的第三方许可信息。未将Flutter SDK、JDK、Maven、PostgreSQL测试工具链或依赖下载缓存复制为项目源码。

此交付尚未指定整个项目对外开源时的许可证，也未公开发布。准备分发或开源前，应重新核查依赖版本、许可证、字体授权及生成产物中的声明。

Passkey 服务端使用 Yubico java-webauthn-server（webauthn-server-core 2.10.1，BSD 2-Clause；[官方项目与许可证](https://github.com/Yubico/java-webauthn-server)）。签名、认证器数据和凭据归属验证由该维护库执行。依赖版本及其传递依赖以 Maven 解析结果和随发行包提供的原始许可证为准。

原生 HTML 排版使用 flutter_widget_from_html_core 0.17.4（MIT）、html 0.15.7 与 csslib 1.0.2（BSD 类许可证，以发行包 LICENSE 为准）；不启用 WebView 或外部资源混入。Android 会话保险库显式依赖 AndroidX Biometric 1.1.0，使用系统认证和 AndroidKeyStore；完整许可证以 Gradle/Maven 发行包原文为准。
