# 版本与兼容性说明

## 默认组合

| 平台 | Lynx / PrimJS | Service / XElement | 默认启用 |
|---|---|---|---:|
| Android | Maven `4.0.0` | Maven `4.0.0` | 是 |
| iOS | CocoaPods `4.0.0` | CocoaPods `4.0.0` | 是 |
| HarmonyOS | PrimJS `4.0.0` | OHPM `1.4.0` | 是 |
| Sparkling Playground UI | `main` 源码参考 | iOS 默认首页，重新构建为 Lynx 4.0 Bundle | 否 |
| Sparkling Native Runtime | `main` 源码参考 | 不加入默认主链路 | 否 |

HarmonyOS `release/4.0` Explorer 使用 `parameter.json` 将 `@lynx/*` 指向 `1.4.0`，根工程的 `@lynx/primjs` 仍为 `4.0.0`。这是平台包发布编号差异，不应把 Harmony OHPM 坐标改写成不存在的 `4.0.0`。

## XElement 边界

- Android：`xelement` 聚合产物 + Input、Overlay、ViewPager、ScrollCoordinator、SVG、Markdown、Refresh、BlurView、WebView；
- iOS：`Behavior` + 九类组件 subspec；
- HarmonyOS：源码目录包含 BlurView、Input、Markdown、Overlay、Refresh、ScrollCoordinator、SVG、ViewPager、WebView 共九类。

三端都不加入不属于 `release/4.0` 边界的 Video 组件。详见 [XELEMENT_INTEGRATION.md](XELEMENT_INTEGRATION.md)。

## HarmonyOS 工程边界

官方 Explorer 是源码仓内工程：包含本地模块 override、多个本地 `srcPath`、GN/Hvigor 插件和 CMake。当前业务壳使用已经发布的 OHPM 包，因此删除：

- `file:../../platform/harmony/...` override；
- Lynx Core 本地模块；
- `externalNativeOptions`；
- GN Bundle/Core 构建插件；
- Scanner、Recorder、UITest、Showcase。

保留的兼容基线：

- HarmonyOS SDK `5.0.1(13)`；
- Stage 模型；
- 建议 DevEco Studio `5.0.13.200+`；
- `@ohos/imageknifepro 1.0.9`。

## 为什么不直接编入 Sparkling main

本次不把 Sparkling iOS 原生依赖与 Lynx 4.0 混装。iOS 默认首页只复刻其 ReactLynx
页面结构，并使用当前工程锁定的 Lynx 4.0 前端工具链重新构建；原生能力全部直接调用
手写的 `NativeModules.LynxShellModule`。

`android/integration/sparkling` 与 `ios/Integration/Sparkling` 中的 `.sample` 不参与默认编译。HarmonyOS 当前没有复制一个未经官方验证的 Sparkling Runtime 适配层。
