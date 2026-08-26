# Router 内置 OTA Runtime

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
        // 本地 Bundle 有效时，页面打开触发当前 appId 后台检查的间隔；默认 30 分钟。
        pageRefreshIntervalMillis = 30L * 60L * 1000L,
    ),
)
```

## 页面打开

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
- 全量响应中的 `bundleLists[*].lynxAppId` 是唯一身份来源；宿主不需要预置默认 App ID，SDK
  按返回身份分别保存 current/previous 和 Bundle 文件。
- APK 内置 baseline 只从 `AssetManager` 直接读取并校验，不复制到 `filesDir`；磁盘 Store
  只保存远程下载的 Release 和事务状态。
- 本地 current 通过 SHA 校验：合法旧版本立即打开，当前 appId 只有超过默认 30 分钟才在后台更新。
- 本地缺包或 SHA 不一致：Activity 显示原生 Loading，只同步当前 appId，完成下载、大小/SHA
  校验和原子激活后再创建 LynxView；这条修复链路不受 30 分钟限制。
- OTA API 与 Manifest Bundle URL 只允许 HTTPS；远程 Manifest 必须是 `ACTIVE`，Bundle `size`
  必须为 `1..20971520` 字节，下载流超过 20 MB 会立即停止并清理 `.part`。
- 同一个 Release 的 Bundle 使用最多 4 个 worker 并发下载/复制；不同 appId 的 Release
  仍由外层队列串行处理，避免一次更新占满设备网络和磁盘。
- 单个 Bundle 下载失败时最多尝试 3 次（首次 + 2 次重试），重试之间做短暂退避；3 次仍失败
  才终止整个 Release 事务。
- 并发任务只写各自的 staging `.part` 文件；全部任务完成后才按 Manifest 顺序发布文件并
  提交 current/previous。任一任务失败都会取消其余任务并清理 staging，不会激活半成品。
- 首屏渲染失败：按 appId 回滚一次并重试，禁止坏版本无限循环。
- 可选 candidate 模式：`stage candidate -> trial -> 首屏健康确认 -> promote current`；
  Native Tab 不消费 candidate，进程重启会清理未完成 trial。
- 无 clientToken 时为 embedded-only，启动/前台/页面缺包均不发 OTA 请求。

## 存储边界

默认目录为：

```text
<application filesDir>/lynx-ota-store/
├── states/<safeAppId>.json
├── states/<safeAppId>.candidate.json   # candidate 模式才存在
├── releases/<releaseId>/<bundlePath>
└── .staging/                   # 事务完成后不应被路由读取
```

`states/<appId>.json` 保存 `current/previous={kind,releaseId}` 指针；Bundle 本体位于已发布的
Release 目录，不把下载 Bundle 的绝对路径写入 state。
路由只读取已提交 current，不读取 `.part` 或 `.staging`。

candidate 文件只保存逻辑 scope、releaseId、状态和 trial 时间；它不会改变 current。普通
Activity 首屏成功后由 runtime promote，首屏失败由容器 discard；Tab 永远只调用
`resolveCurrent`。

验收页或 Lynx 页面可以调用以下入口直接删除磁盘内容：

```kotlin
// 只删除一个 appId 的 releases、staging 和下载指针
LynxRouter.deleteOtaBundles(returnedBundle.lynxAppId) { success, message -> }

// 删除 releases 下全部 appId 的 Bundle
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

这两个 API 是永久删除，不会改名生成 `.delete-*`、`.legacy-*` 或其它备份目录；APK
内置 `embedded-release` 描述和 assets 不会被删除。删除失败会返回失败并保留失败原路径，
不伪造成功，便于页面提示用户关闭正在使用的容器后重试。旧的
`LynxRouter.clearOtaCache()` 仍保留为“删除全部下载内容”的兼容别名。

## 源码边界

OTA 核心源码位于 `src/main/kotlin/com/ota/android/sdk`，由 Router AAR 一起编译和发布；
`ActivityBundleRuntime` 仍然保留为可选扩展口，允许已有宿主替换网络层，但不再是三方接入
内置 OTA 的必需步骤。

Android 端对等测试和真机证据见仓库根目录 `docs/android-ota-test-report.html`。
