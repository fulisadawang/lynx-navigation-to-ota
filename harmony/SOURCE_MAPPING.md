# HarmonyOS 官方源码映射

| 壳工程职责 | Lynx release/4.0 参考位置 |
|---|---|
| 构建与 SDK 边界 | `explorer/harmony/README.md`、`build-profile.json5` |
| OHPM 依赖 | `explorer/harmony/parameter.json`、`lynx_explorer/oh-package.json5` |
| Runtime 初始化 | `lynx_explorer/src/main/ets/common/LynxInitProcessor.ets` |
| Ability 启动 | `entryability/EntryAbility.ets`、`LynxAbilityStage.ets` |
| LynxView 组装 | `pages/Lynx.ets` |
| Template Fetcher | `provider/ExampleTemplateResourceFetcher.ets` |
| Generic Fetcher | `provider/ExampleGenericResourceFetcher.ets` |
| Media Fetcher | `provider/ExampleMediaResourceFetcher.ets` |
| Native Module | `module/ExplorerModule.ets` 与 Lynx 4.0 Native Modules 指南 |
| XElement 源码边界 | `platform/harmony/lynx_xelement` |

本壳保留上述宿主机制，但删除 Explorer 的展示/扫描/测试职责，并为业务接入补充了请求限制、统一模型、错误态、重试和注释。

## Sparkling 边界

Sparkling `main/packages/playground` 当前没有 HarmonyOS 原生 Playground。本壳只兼容其 `hybrid://lynxview_page` 路由和分层思想，不声明未经官方源码证明的 Harmony Runtime 适配；说明见 `integration/sparkling/README.md`。
