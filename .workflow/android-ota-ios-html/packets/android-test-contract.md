# Packet: android-test-contract

## Result

Android 当前 JVM 测试已覆盖 URL/size/status、校验缓存和部分 ReleaseTransaction fallback；当前工作树新增测试覆盖 direct predecessor、损坏 current、损坏 predecessor。仍缺少 Android 版 iOS F01-F18 的运行态对等证据。

## Required parity matrix

| Area | Android proof required |
|---|---|
| Version visibility | 手机屏幕必须同时显示 appId、releaseId、source、bundleName；App version 与 OTA release 分开识别 |
| Load parity | 同一 `(lynxAppId, bundleName)` 的 Activity 与 Tab 使用同一 current/embedded 结果 |
| Lifecycle | cold start 与 foreground 各触发 host 全量同步；重叠回调合并，不让 Tab 自己联网 |
| Refresh | 主动刷新成功后所有 Tab 重新读 current；失败保留现有实例/版本 |
| Recovery | 首屏失败优先 previous remote，再 fallback embedded；恢复后 provenance 正确 |
| Durable state | state commit/rollback commit 后进程终止，下一进程仍读取完整 current/previous |
| Network boundary | 无 token/服务不可达时不得把 mock 或错误响应冒充 live；已有本地版本继续可用 |
| Optional activation | iOS 已有 candidate/trial/healthy-confirm；严格跨端一致要求 Android 提供同样的 opt-in 能力 |

## Evidence policy

JVM 单测只能证明 SDK/事务；APK 构建只能证明可安装产物；AndroMeld 真机才证明屏幕版本、Tab 实例和真实 live OTA。报告按证据层级拆开，不用静态调用链代替真机行为。

## Decision

本轮必须新增 Android 的 candidate API、首屏 recovery、来源标识和可观测 debug state；instrumented target 若现有工程缺依赖则不伪造通过，使用 AndroMeld 真机证据并明确自动化边界。
