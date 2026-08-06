# XElement 全量与 HarmonyOS 增补记录

修订日期：2026-07-29。

## Android / iOS 全量修订

1. Android 显式接入 Explorer `release/4.0` 的 10 个 Maven 坐标；
2. Android 增加统一 `XElementRuntime`、配套依赖和 R8 保留规则；
3. iOS 将隐式默认 subspec 改为 10 项显式清单；
4. iOS 导入全部组件和 AutoRegistry 头，并为静态 Framework 配置 `-ObjC`；
5. Android/iOS 静态验收为 `52 PASS / 0 WARN / 0 FAIL`。

## HarmonyOS 新增

1. 新增标准 OHPM 业务壳，不依赖 Lynx monorepo 本地 override、GN 或 CMake；
2. PrimJS 固定 `4.0.0`，Harmony `@lynx/*` 按官方映射固定 `1.4.0`；
3. 补齐 Log、DevTool、HTTP、Image Service 和 `LynxEnv` 初始化顺序；
4. 按 `release/4.0` 真实边界接入 XElement 9/9；
5. 新增 Template/Generic/Media Provider、路由、安全策略、原生错误态和重试；
6. 新增 ArkTS `LynxShellModule`，与 Android/iOS 七个方法对齐；
7. 新增 Stage 模型、ArkUI 首页、单页容器、深链和 rawfile Bundle；
8. HarmonyOS 静态验收为 `45 PASS / 0 WARN / 0 FAIL`；
9. 三端合计为 `97 PASS / 0 WARN / 0 FAIL`。

请使用文件名包含 `Android-iOS-Harmony-XElement-Full` 的新完整包。
