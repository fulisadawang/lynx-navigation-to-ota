# 官方源码参考映射

核对分支：Lynx `release/4.0`；Sparkling `main`。

## Android / iOS Explorer

参考职责：

- Android Application、`LynxViewShellActivity`、Service、Builder、Provider、XElement；
- iOS Runtime 初始化、`LynxViewShellViewController`、Provider、Native Module、XElement AutoRegistry；
- `initData`、`globalProps`、尺寸、方向和生命周期；
- Explorer 非标准 `file://lynx?local://...?...` 本地地址。

本壳没有复制 Explorer 的 DevTool 页面、Recorder、扫码、Showcase 和测试 UI。

## HarmonyOS Explorer

| 壳工程职责 | `release/4.0` 参考位置 |
|---|---|
| 项目与构建边界 | `explorer/harmony/README.md`、`build-profile.json5` |
| 版本映射 | `explorer/harmony/parameter.json`、根 `oh-package.json5` |
| OHPM 依赖 | `explorer/harmony/lynx_explorer/oh-package.json5` |
| Runtime / Service | `common/LynxInitProcessor.ets` |
| Ability 启动 | `entryability/EntryAbility.ets`、`LynxAbilityStage.ets` |
| LynxView 组装 | `pages/Lynx.ets` |
| Template Provider | `provider/ExampleTemplateResourceFetcher.ets` |
| Generic Provider | `provider/ExampleGenericResourceFetcher.ets` |
| Media Provider | `provider/ExampleMediaResourceFetcher.ets` |
| Native Module | `module/ExplorerModule.ets` 与 Lynx 4.0 Native Modules 文档 |
| XElement 边界 | `platform/harmony/lynx_xelement` |

业务壳保留官方 Runtime、View、Fetcher、Module 和 XElement 的使用方式，同时删除源码仓内本地 override、GN/CMake、Scanner、Recorder、UITest 与示例列表，并补充统一模型、安全策略、错误态和注释。

## Sparkling Playground

参考职责：

- Bootstrap、Context、Provider、Router、Method 的隔离；
- `hybrid://lynxview_page?bundle=...` 参数兼容；
- Router、Storage 等稳定 Method 名称；
- Debug/Release 能力隔离。

Sparkling Runtime 本身没有进入 Lynx 4.0 默认依赖链。

## 源码性质

本工程是按业务宿主职责重新组织的示例实现，不是官方 Demo 的整文件复制。许可证边界见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
