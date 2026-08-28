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

## OTA Store v2 层

`ReleaseTransaction` 只管理远程 OTA 文件，不管理 rawfile 内置 Bundle：

```text
<context.filesDir>/lynx-ota-store/apps/<lynxAppId>/
├── state.json
├── releases/<releaseId>/release-manifest.json + Bundle files
└── .staging/<releaseId>.<transactionId>/
```

状态文件使用 schema v2，只包含 `current/previous`；本端不实现候选版本状态机。每次发布先在
App ID 目录下完成 staging、size/SHA 校验、完整 Manifest 校验和可用空间预检，再最后写入 state。
写入后 prune 历史 Release，只保留 current、previous 和仍被 Page/Tab lease 使用的目录。

`OtaBundleLease` 与 `PreparedPageBundle` 一起返回给容器。Runtime 的操作队列同时串行化下载、
发布、删除、冷启动清理和 lease 释放后的 prune，避免异步网络事务期间误删尚未提交的 Release。

`OtaStorageDiagnostics` 只读扫描 Runtime 已绑定的 Store root，提供 Inspector 所需的路径、角色、
文件树和字节统计，不接受任意外部路径。

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
