# HarmonyOS Telemetry Phase 1 Alpha

这里是 `lynx_shell_kit` HAR 的本地观测协调层，不依赖 Lynx Performance 的未确认 ABI。

## 与 Wire Schema 3.0.0 的映射

- `TelemetryIdentity`：统一 `navigationId`、`navigationSessionId`、`entryId`、`pageViewId`、`renderAttemptId`、`activationId`、`transactionId`。
- `AttemptedBundleSnapshot` / `ResolvedBundleSnapshot` 的 `source` 在 Wire 层命名为 `bundleSource`。
- `TelemetryEvent` 使用 `attemptedBundleSnapshot` / `resolvedBundleSnapshot`，并带 `analysisEligible`、`deliveryOwner`。
- 绝对 `internalLocalPath` 只给本地加载链保留，不应送入 Telemetry。

`TelemetryCoordinator` 由 ArkUI Page、Router 和 LynxViewClient 提交事实，负责页面/App 正交状态、首屏幂等、导航受理、转场终态、stale callback 和 OTA snapshot。默认 Noop Sink；Debug Sink 是有界内存实现。

当前阶段不接网络、磁盘队列、生产 uploader 或未核实 Lynx 4.0 Performance 回调。HarmonyOS HAP/真机构建必须另行验证，不能以本目录 fixture 代替。
