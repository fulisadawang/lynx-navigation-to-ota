# 版本与兼容性说明

## 默认组合

| 平台 | Lynx / PrimJS | Service / XElement | 默认启用 |
|---|---|---|---:|
| Android | Lynx/Service/XElement `4.1.0`；PrimJS `4.1.1` | 同左 | 是 |
| iOS | Lynx/Service/XElement `4.1.0`；PrimJS `4.1.1` | 同左 | 是 |
| HarmonyOS | Lynx/Service/XElement `4.1.0`；PrimJS `4.1.1` | OHPM 官方包 | 是 |
| Sparkling Playground UI | `main` 源码参考 | iOS 默认首页，重新构建为 Lynx 4.1 Bundle | 否 |
| Sparkling Native Runtime | `main` 源码参考 | 不加入默认主链路 | 否 |

HarmonyOS 当前使用官方 Lynx/Service/XElement `4.1.0` OHPM 包和 PrimJS `4.1.1`；版本通过根 `parameter.json` 传递，不能把 Android Maven 坐标机械改写成不存在的 Harmony 包。

## XElement 边界

- Android：`xelement` 聚合产物 + Input、Overlay、ViewPager、ScrollCoordinator、SVG、Markdown、Refresh、BlurView、WebView、Video；AnimaX 宿主接入由独立分支维护；官方聚合器可能携带其传递依赖。
- iOS：`Behavior` + 现有组件和 Video subspec；AnimaX 因 iOS 13/SSZipArchive 兼容问题延期；
- HarmonyOS：核心 Registry 加 BlurView、Input、Markdown、Overlay、Refresh、ScrollCoordinator、SVG、ViewPager、WebView、Video 共十类。

Video 是 4.1 的实验性组件，Android/iOS/HarmonyOS 均按官方依赖接入；AnimaX 不进入本升级分支，详见 [XELEMENT_INTEGRATION.md](XELEMENT_INTEGRATION.md)。

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

本次不把 Sparkling iOS 原生依赖与 Lynx 4.1 混装。iOS 默认首页只复刻其 ReactLynx
页面结构，并使用当前工程锁定的 Lynx 4.1 前端工具链重新构建；原生能力全部直接调用
手写的 `NativeModules.LynxShellModule`。

`android/integration/sparkling` 与 `ios/Integration/Sparkling` 中的 `.sample` 不参与默认编译。HarmonyOS 当前没有复制一个未经官方验证的 Sparkling Runtime 适配层。
