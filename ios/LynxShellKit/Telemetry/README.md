# iOS Telemetry Phase 1 Alpha

这里是 `LynxShellKit` 的本地观测协调层，不是独立 OTA 或网络上报 SDK。

## 与 Wire Schema 3.0.0 的映射

- `LynxTelemetryIdentity`：`navigationId`、`navigationSessionId`、`entryId`、`pageViewId`、`renderAttemptId`、`activationId`、`transactionId`。
- `LynxAttemptedBundleSnapshot`：序列化键使用 `kind`、`bundleSource`、`bundleName`、`telemetryRouteKey` 等 canonical 字段。
- `LynxResolvedBundleSnapshot`：同样使用 `bundleSource`；`internalLocalPath` 只保留在进程内，`Codable` 明确排除。
- `LynxTelemetryEvent`：`attemptedBundleSnapshot` / `resolvedBundleSnapshot`、`analysisEligible`、`deliveryOwner` 已采用共享契约命名。

`LynxTelemetryCoordinator` 只负责构造事实事件：Router admission、UIViewController 页面状态、Scene App 前后台、首屏、转场终态、stale callback 和 OTA snapshot。默认 `LynxNoopTelemetrySink`，调试才使用有界 `LynxDebugTelemetrySink`。

宿主 SceneDelegate 需要显式转交 App 生命周期：

```swift
func sceneWillEnterForeground(_ scene: UIScene) {
    LynxRouter.onApplicationForeground()
}

func sceneDidEnterBackground(_ scene: UIScene) {
    LynxRouter.onApplicationBackground()
}
```

Router 不会把单个 UIViewController 的 hidden 事件猜成 App background；两个状态由 Coordinator
分别记录。

当前没有接入 Lynx 4.0 未确认的 Performance ABI，也没有网络、磁盘队列或 durable uploader；因此不能把本目录称为生产监控已上线。
