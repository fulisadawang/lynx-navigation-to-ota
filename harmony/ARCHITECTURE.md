# HarmonyOS 壳工程架构

## 启动层

`LynxAbilityStage` 只保留 Stage 生命周期入口。ImageKnife、Service、LynxEnv 与 XElement 统一由
HAR 的 `LynxRuntimeInitializer` 初始化，保证 Entry 只直接依赖 `@lynx/lynx-shell-kit`；
`EntryAbility` 负责 WindowStage 保存、OTA 配置、系统配置更新和深链暂存。

初始化顺序固定为：

```text
Log / DevTool / HTTP / Image Service
        ↓
LynxEnv.initialize
        ↓
LynxEnv.setAppInfo
        ↓
XElementMarkdown.initialize
```

## 页面层

`Index` 是 Demo 的原生 ArkUI 启动页；可复用 `lynx_shell_kit` HAR 提供单页面
`LynxContainer`，Entry 仅保留 `@Entry` 包装。容器只接收 `LynxPageRequest`，不直接解析
外部 URL；页面默认不叠加原生标题栏。`animated=false` 由 Entry 包装页的
`pageTransition()` 用零时长 enter/exit 覆盖系统页面转场，HAR 容器同步保留同一能力以便其他宿主复用。

## Module 层

`lynx_shell_kit` 是可复用 HAR Module，公开包名为 `@lynx/lynx-shell-kit`，承载
Runtime 初始化、XElement、Provider、Bridge、路由和容器。`lynx_shell` 是可运行 Demo，
负责 Ability、首页、Bundle rawfile、签名和页面入口。

## 资源层

- `ShellTemplateResourceFetcher`：Bundle 与 SSR 数据；
- `ShellGenericResourceFetcher`：字体、图片和二进制资源；
- `ShellMediaResourceFetcher`：本地逻辑 URL 转 rawfile URL。

## OTA Store v3 层

`ContentAddressedOtaStore` 只管理远程 OTA 对象，不管理 rawfile 内置 Bundle。内置 Bundle 是
HAP 发布资产，首次命中时直接读取；远程对象才进入 App ID 作用域的 CAS：

```text
<context.filesDir>/lynx-ota-store/apps/<lynxAppId>/
├── state.json
├── manifests/<manifestId>.json
├── objects/<sha 前两位>/<sha>.lynx.bundle
└── transactions/<transactionId>/*.part
```

状态文件使用 schema v3，只包含 `current/previous`；本端不实现候选版本状态机。服务端下发的
`changedBundles` 仍是完整 Manifest 快照，但客户端按 SHA 查找 App ID 内的 CAS 对象：命中则复用，
未命中才下载到 `transactions/` 临时文件。每个对象先完成 size/SHA 校验，再原子发布对象、Manifest，
最后原子写入 state；state 是唯一激活点。写入后执行 Mark-and-Sweep，只保留 current、previous、
活跃 Page/Tab lease 引用的 Manifest 和对象。

`OtaBundleLease` 与 `PreparedPageBundle` 一起返回给容器。Runtime 的操作队列同时串行化下载、
发布、删除、冷启动清理和 lease 释放后的 prune，避免异步网络事务期间误删尚未提交的 Release。

`LynxOtaRuntime.storageSnapshot()` 只读扫描 Runtime 已绑定的 Store root，提供 Inspector 所需的
路径、Manifest、current/previous、lease、CAS 对象和字节统计，不接受任意外部路径。旧的
`ReleaseTransaction`/`OtaStorageDiagnostics` 文件仅作为源码历史兼容物保留，不属于当前 Runtime
主链，也不再从 HAR 公开入口导出。

## 路由层

`LynxRouteParser` 统一解析 Explorer、Sparkling 和 `lynxshell` 协议；`LynxNavigator` 统一 ArkUI Router 调用。

## Bridge 层

`LynxShellModule` 是 HAR 中唯一的 Bridge 实现，暴露基础存储/AppInfo、完整导航栈方法和
准备/转场状态方法；不把页面类、Ability 或 Preferences 对象泄漏给 Lynx JS。媒体/文件方法
目前显式返回 `1004` 未接入，不伪造成功结果。

## 与 Explorer 的差异

官方 Explorer 位于 Lynx monorepo 内，需要本地 override、GN/Hvigor 插件、CMake 与示例 Bundle 构建。本壳使用已发布 OHPM 包，因此：

- 根工程包含 `lynx_shell_kit` HAR 与 `lynx_shell` entry Demo；
- 不包含 Lynx Core 本地模块；
- 不包含 `file:../../platform/harmony/...` override；
- 不执行 GN 或 Python bundle 构建插件；
- 不携带 Scanner、Recorder、UITest、示例列表。
