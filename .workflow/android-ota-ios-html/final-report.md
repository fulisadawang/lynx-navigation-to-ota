# Final Report: Android OTA 与 iOS 一致性实现、真机验收和 HTML 报告

## Outcome

Android OTA + Router 已完成与 iOS 行为契约的核心对齐，并在 IN2010 Android 13 真机上完成真实服务 smoke。内置 baseline、启动全量同步、下一次冷启动使用 OTA current、Native Tab cache-only、主动刷新重载和版本可见性均有证据；候选版本和 durable transaction 在 JVM 层有对等测试。

## Accepted Results

- Android `ReleaseTransaction` 增加 candidate pending/trial/healthy promote/discard/recover、rollback fault points，并保持 current/previous 原子状态。
- `OtaSdk` 和 `LynxOtaRuntime` 增加 candidate API；Activity 普通页面可消费 candidate，Native Tab 仍固定读 current。
- Android 首屏 `onReceivedError` 进入一次性 OTA recovery；previous remote 保持 `ota_current`，只有 embedded 恢复标记 `rollback_fallback`。
- Demo appId 从 `embedded-bundles.json` 的唯一 Bundle 集合推导，不按文件名猜身份。
- 无 token 时 runtime 进入 embedded-only，不触发启动/前台/页面缺包网络请求。
- `scripts/ota-fault/run.sh --platform android --tier sdk --case all` 可执行；Android JVM 26/26 通过。
- 真实服务返回 2 个 appId；真机屏幕完成 embedded -> OTA current 的冷启动切换及 Tab/单独页面一致性核对。
- 交互报告已生成：`docs/android-ota-test-report.html`。

## Rejected Results

- Android instrumentation/Espresso/UIAutomator 尚未配置，未将 adb/截图当作自动化 UI 通过。
- 真实服务本轮没有高于 embedded 的 releaseId，未声称 V1 -> V2 release delta。
- 真机首屏故障注入到 embedded fallback 已通过；两个不同 remote release 的 previous rollback + rollback commit 后 force-stop 尚未闭合。

## Conflicts Resolved

- “Tab 每次切换请求网络”与既定产品契约冲突，保留 cache-only；网络只由 Application 生命周期或用户主动刷新发起。
- “从 bundle 文件名推导 appId”与多 appId 同名 Bundle 的隔离要求冲突，改为 Manifest 唯一 identity 推导，生产宿主仍需显式传完整 identity。
- Android 原有 rollback fallback 来源覆盖过宽，按 iOS 语义拆分 previous remote 与 embedded fallback。

## Verification Evidence

详见 `results/verification.md`：单测、静态检查、构建安装、真实 API、IN2010 真机截图/Activity/logcat/run-as、HTML/secret 自检均有记录。

## Remaining Risks

- 服务端发布新 Android release 后，需要重跑报告中的 live delta 用例。
- 如需 CI 级真机回归，需要补 Android instrumentation runner、稳定 accessibility/debug state、first-screen fault injector 和 force-stop 流程。
- 本分支保留用户已有 iOS/Podfile.lock 改动；没有进行无关回滚或提交。

## Reusable Follow-up

- 使用 `bash scripts/ota-fault/run.sh --platform android --tier sdk --case all` 做本地 SDK 回归。
- 使用 `docs/android-ota-test-report.html` 的筛选器按 `JVM / SDK`、`真机 / adb`、`真实 OTA` 查看证据。
- 新 release 发布后复用 `A-02/A-05/A-06/A-07/A-10/A-16` 验证真实版本变化。

## 2026-08-27 Final Test Follow-up

- Android 使用已连接的 IN2010 真机 `a7e90f03` 完成聚焦复验：OTA JVM 19/19、motion JVM 7/7、candidate 同步、正常 promote、首屏故障 discard 和 `candidate 发布后不可读取` 竞态回归均通过；异常计数为 0。
- Android 最小修复位于 `android/lynx-shell/src/main/kotlin/com/ota/android/sdk/OtaSdk.kt`：candidate 在后台同步与页面消费之间合法消失时，重新读取 current 并返回稳定结果，不再把 promote/discard 竞态报告成激活失败。
- Android 仍未验证“已有 stable downloaded current + 新 candidate 首屏失败后保留 stable current”，原因是本轮真实服务每个 App ID 只有一个 latest release，不能在不伪造私有 state 的情况下构造双版本前置条件。
- iOS 使用 Build iOS Apps / XcodeBuildMCP 在 iPhone 16 Pro / iOS 18.1 Simulator 上完成真实 live smoke：`testLiveOtaServerRefreshSmoke` 通过，`1 passed / 0 failed`，约 15.3 秒；凭据只存在 test runner 环境，不进入报告。
- iOS 本轮没有修改源代码；此前无凭据 runner 的 skip 和一次环境注入超时均保留为历史证据，已由本轮有效 XcodeBuildMCP `testRunnerEnv` 结果补齐 live smoke。
- 证据索引：`/tmp/lynx-android-final-test-result-v2.txt`、`/tmp/lynx-ios-final-test-result.txt`、Android v2 logcat/state 文件、XcodeBuildMCP result bundle（路径已写入 HTML 报告关联结果）。
