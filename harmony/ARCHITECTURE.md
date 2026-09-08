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

状态文件使用 schema v3，远程引用只有 current/previous，另保存 ref selection、selectionSchemaVersion 与 lastDecision；本端不实现候选版本状态机。服务端下发的
`changedBundles` 仍是完整 Manifest 快照，但客户端按 SHA 查找 App ID 内的 CAS 对象：命中则复用，
未命中才下载到 `transactions/` 临时文件。每个对象先完成 size/SHA 校验，再原子发布对象、Manifest，
最后原子写入 state；state 是唯一激活点。写入后执行 Mark-and-Sweep，只保留 current、previous、
活跃 Page/Tab lease 及未完成 transaction 引用的 Manifest 和对象。

`OtaBundleLease` 与 PreparedPageBundle 的 epoch/selection 一起返回。Runtime 使用身份分代队列，B 不等 A 长 HTTP；
cache-only lease 读取不走网络队列。async 操作显式传只读 OtaUserContext，禁止全局 operationContext 跨 await。
同步注册增 epoch；最终同步 State rename 前验证 epoch 与 lastDecision，同步段内没有 await；旧 close 不被身份失效阻止。

完整 Manifest 100 包只改050时新增下载/对象1、复制0。有界GC只保留current/previous、lease和事务，旧回滚对象已GC允许补缺1，
不无限保存历史。正在下载的事务保护其对象和Manifest，成功后退休已结束索引，不能删除另一epoch活跃事务。

## 用户、版本与页面消费

原生 `LynxRouter.registerOtaUserId/clearOtaUserId` 支持 install 前调用，同身份不重复同步。Runtime 使用自身 BundleInfo.versionCode 与
真实 HAR `LynxEnv.getLynxVersion()`，Models 只校验，不使用固定BUILD_NUMBER；所有请求固定platform=harmony，无Android兼容降级。
全量/定向/repair/主动刷新使用精确 `versioncode`、`lynxSdkVersion` 与可选 userId，构建码独立于版本名称。

Server 先用户/范围过滤，再比较releaseSequence，full7胜gray6；policyRevision防旧决定，高修订可回滚低序号，均用字符串精确十进制比较。
State lastDecision只含audience/context摘要、revision、action与target，不保存rawID、不是GC root；CAS不新增用户目录。
unknown旧v3引用等Server新确认，current/previous/Snapshot都重检audience与native/SDK范围，明确embedded指令冷启仍有效。

全批协议先校验，再独立提交每App决定，最后下载，保留partial失败而不跳过其他App撤销。
Tab普通切换cache-only、后台更新不重建；身份或主动刷新完成后按有效epoch reset Snapshot/generation并重读State，包含partial failure。
首屏回滚原子校验expected current；无适用previous时同次提交embedded哨兵，宿主不追加第二次delete。

本次非设备门禁：host-final3 mode=all 18/18（5真实HTTP）＋Core25/25，0失败/跳过；release HAR3.981s/App6.565s构建成功，静态90/0/0。
当前产物见 [Harmony user-gray报告](../docs/harmony-ota-user-gray-test-report.html)，HTML展示验收独立记录。
用户取消本次 Harmony 模拟器测试，真机本轮未验收；[历史v3报告](../docs/harmony-ota-store-v3-test-report.html) 不代表本次灰度运行验证。

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
