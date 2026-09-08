# Router 内置 OTA Runtime（Store v3）

`lynx-shell` 现在同时包含 Router、Lynx 容器和 Android OTA Runtime。三方接入不需要再
引入外部 `sdk-0.1.0.jar`，也不需要复制 Demo 的 OTA 适配器。

## Application 初始化

```kotlin
LynxRouter.install(
    this,
    LynxOtaConfig(
        apiBaseUri = URI.create("https://lynx-ota-server.example.com"),
        hostApp = "capp",
        environment = "PROD",
        platform = "android",
        clientToken = BuildConfig.LYNX_OTA_CLIENT_TOKEN,
        storeVersion = OtaModels.StoreVersion.V3,
        // 本地 Bundle 有效时，页面打开触发当前 appId 后台检查的间隔；默认 30 分钟。
        pageRefreshIntervalMillis = 30L * 60L * 1000L,
    ),
)
```

## 用户注册与真实版本

原生主线程可在 install 前或运行期间调用 `LynxRouter.registerOtaUserId(userId)`，退出调用 `clearOtaUserId()`。
相同规范化身份不重复同步；变化后 epoch 立即失效旧响应、页面导航和 candidate 回调，并合并一次新身份全量检查。
注册返回值不是网络完成信号。userId 先拒绝 raw 控制字符再 trim，不持久化明文账号。

`LynxOtaConfig.versionCode` 默认取 PackageInfo.longVersionCode / versionCode，不使用 versionName；合法显式值优先。
HTTP 字段精确为 `versioncode`、`lynxSdkVersion`、可选 userId，匿名省略 userId。构建码是正十进制字符串，与 buildNumber 上报独立。
实际 SDK 版本由当前 Library variant 的 resolved Lynx 依赖生成 `BuildConfig.LYNX_RUNTIME_VERSION`，不能使用误报的 JNI getter。
预编译 AAR 被宿主强行解析到另一 Runtime 版本不属于已认证组合，需要重建并验证，不把 Library BuildConfig 当作任意宿主替换后的探测器。

Server 按资格和兼容范围过滤后比较 releaseSequence，full7 胜 gray6；policyRevision 防旧决定，高修订可回滚低序号。
Core Configuration 的尾参 versionCode=null 仅保留旧低层兼容；新版 Router 使用完整 context 与 Store v3。

## 页面打开（逻辑地址）

```kotlin
LynxRouter.open(
    context = activity,
    lynxAppId = returnedBundle.lynxAppId,
    bundleName = returnedBundle.bundleName,
    params = mapOf("orderNo" to "A1001"),
)
```

Router 不要求 route registry，也不把本地绝对路径写入 Intent。`bundleName` 必须来自
服务端 Manifest 的精确 `bundlePath`，Bundle 文件名相同时也必须通过 `lynxAppId` 隔离。

## 生命周期和下载策略

- Application 启动、回到前台：每次异步同步宿主下所有 appId，不走 30 分钟门控。
- 全量 bundleLists/directives 中的 lynxAppId 是 App 身份来源；整批 selection 协议先校验，各 App 决定先落盘，再逐 App 下载。部分失败保留 partialResult/failures，不跳过其他 App 的成功或撤销。
- APK 内置 baseline 只从 `AssetManager` 直接读取并校验，不复制到 `filesDir`；磁盘 Store
  只保存远程下载的 Release 和事务状态。
- 本地 current 通过 audience、native code/SDK 范围及 SHA 校验后立即打开，当前 appId 只有超过默认 30 分钟才在后台更新。
- 本地缺包或 SHA 不一致：Activity 显示原生 Loading，只同步当前 appId，完成下载、大小/SHA
  校验和原子激活后再创建 LynxView；这条修复链路不受 30 分钟限制。
- OTA API 与 Manifest Bundle URL 只允许 HTTPS；远程 Manifest 必须是 `ACTIVE`，Bundle `size`
  必须为 `1..20971520` 字节，下载流超过 20 MB 会立即停止并清理 `.part`。
- 下载 worker 显式捕获和恢复 ThreadLocal context；未变 CAS 对象只复用引用，不复制。每个 epoch 有独立刷新队列，B 不必等待 A 的长 HTTP；cache-only lease 读取不经过网络队列。
- 单个 Bundle 下载失败时最多尝试 3 次（首次 + 2 次重试），重试之间做短暂退避；3 次仍失败
  才终止整个 Release 事务。
- 未完成 bytes 写入事务 `.part`；完整 Object/Manifest 就绪才提交引用。State 最终 rename 与注册共用身份锁，并复核 revision，任何失败都不能激活半成品；事务 roots 保留必要恢复对象。
- 首屏渲染失败：按 appId 回滚一次并重试，禁止坏版本无限循环。
- 可选 candidate 模式：`stage candidate -> trial -> 首屏健康确认 -> promote current`；
  Native Tab 不消费 candidate，进程重启会清理未完成 trial。
- 无 clientToken 时为 embedded-only，启动/前台/页面缺包均不发 OTA 请求。
- Native Tab 切换只读当前身份适用版本，普通后台不重建。身份变化/主动刷新完成后重读已提交 State，包括 partial failure；只给成功 App 更新门控。

## 存储边界

默认目录为：

```text
<application filesDir>/lynx-ota-store/
└── apps/<lynxAppId>/
    ├── state.json
    ├── embedded.json                   # 可选逻辑描述，不包含 Bundle bytes
    ├── manifests/<manifestId>.json     # 完整 Manifest 快照
    ├── objects/<sha 前两位>/<sha>.lynx.bundle
    └── transactions/<transactionId>/   # .part 与事务日志
```

`apps/<appId>/state.json` 保存 `current/previous={kind,releaseId,manifestId,selection}` 指针，以及 selectionSchemaVersion 与 lastDecision；Bundle 本体位于
App ID 作用域的 CAS 对象库，不把下载 Bundle 的绝对路径写入 state。完整 Manifest 快照记录每个
`bundlePath -> objectId` 映射，因此新版本只写入缺失对象。
路由只读取已提交 current，不读取 `.part` 或 `.staging`。

服务端 App ID 契约是 8 位数字，可直接作为无碰撞目录段。同名 `releaseId` 允许分别存在于不同
App ID 下。普通激活后只保留 current/previous；candidate 模式额外保留 candidate；活体页面
lease 会阻止旧 Release 被提前删除，容器销毁后立即重新 prune。

lastDecision 保存 audienceKey/clientContextKey/policyRevision/action/target，是选择约束，不是 bytes root。
unknown 旧 v3 ref 在新模式必须等 Server 确认；gray 不能跨用户读取或回滚，native/SDK 变化后 full 也要重新检查范围。
不建 users 目录。完整 100 包仅变 050 时新增下载/对象 1，复制 0；回滚目标已 GC 时可补缺失 1 并复用 99，不无限保存历史。

State 的 candidate 引用保存选择记录与状态，不提前改变 current。`acquireCandidateTrialBundleLease` 原子绑定 trial 与 lease，
confirm/discard 都携带 prepared releaseId/epoch；旧 callback 不得修改新 candidate。普通 Activity 首屏成功后由 runtime promote，首屏失败 discard；Tab 永远只调用
`resolveCurrent`。

验收页或 Lynx 页面可以调用以下入口直接删除磁盘内容：

```kotlin
// 清除一个 appId 的远程引用；必要 State/lastDecision 与 live lease 仍受保护
LynxRouter.deleteOtaBundles(returnedBundle.lynxAppId) { success, message -> }

// 删除 apps 下全部 appId 的远程 Bundle
LynxRouter.deleteAllOtaBundles { success, message -> }
```

Lynx 页面侧对应：

```ts
NativeModules.LynxShellModule.deleteOtaBundles?.(returnedBundle.lynxAppId, (result) => {
  if (result.code === 0) console.log('指定 appId 的 Bundle 已删除');
});
NativeModules.LynxShellModule.deleteAllOtaBundles?.((result) => {
  if (result.code === 0) console.log('全部 Bundle 已删除');
});
```

这两个 API 是永久删除，不会改名生成 `.delete-*` 或其它备份目录；APK assets 和
`embedded.json` 逻辑描述不会被删除。正被活体页面 lease 的 Release 会延迟到最后一个 lease
关闭后删除，不会让已显示页面丢失文件。删除失败不会伪造成功。旧的
`LynxRouter.clearOtaCache()` 仍保留为“删除全部下载内容”的兼容别名。

Demo 原生 Launcher 的“查看 OTA 磁盘目录”通过 `LynxRouter.otaStorageSnapshot()` 展示只读快照；
该调用不联网、不清理 orphan、不重新计算全部 SHA，也不接受任意外部扫描路径。

Store v3 不读取或迁移旧 v2 路径。Demo 验收时卸载旧 App、重新安装，以全新沙盒直接使用最新 schema。

## 源码边界

OTA 核心源码位于 `src/main/kotlin/com/ota/android/sdk`，由 Router AAR 一起编译和发布；
`ActivityBundleRuntime` 仍然保留为可选扩展口，允许已有宿主替换网络层，但不再是三方接入
内置 OTA 的必需步骤。

当前 user-gray 证据：[Android 报告](../../docs/android-ota-user-gray-test-report.html)，87 tests / 0 failure/error/skipped＋APK；本次已取消设备测试。
旧 [Store v3 报告](../../docs/android-ota-store-v3-test-report.html) 及 `android-ota-test-report.html` 是历史证据，不代表本次设备通过。
三端匿名内置脚本及必需 `--versioncode/--lynx-sdk-version` 参数见 [Module 接入](../../MODULE_INTEGRATION.md#三端匿名内置-baseline-下载)。
