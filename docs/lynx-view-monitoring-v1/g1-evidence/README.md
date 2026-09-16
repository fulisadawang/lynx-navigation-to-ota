# G1 三端证据索引

本目录只保存本次 G1 验收所需的脱敏命令输出、Provider snapshot 摘要、UI tree、截图和构建结果。没有 Token、Cookie、业务请求正文或厂商凭据。

## Android

- `50-final-gradle.log`、`60-after-review-gradle.log`、`61-after-monitor-page-fix-gradle.log`：Gradle 测试和 Debug APK 构建。
- `46-snapshot-summary.md`、`46-full-snapshot-logcat.txt`：完整 Page/资源页/Native Tab/reload 流程的 45 条 Provider 事件。
- `63-after-review-runtime.log`、`63-after-review-monitor-summary.log`、`65-after-review-final-monitor.png`：修复创建前 visible 和 Manifest 歧义后的二次回归，快照 25 条。
- `61-after-review-page.png`、`62-after-review-native-tab.png`、`63-after-review-page-fixed.png`、`64-after-review-native-tab-fixed.png`：Page/Native Tab 运行截图。
- `*-crash.txt`：对应场景 ADB crash buffer；最终 `63-after-review-crash.txt` 为空。

## iOS

- `00-static-check-final.log`：Android/iOS 静态门禁，113 PASS。
- `50-final-xcodebuild-summary.log`、`60-after-review-xcodebuild.log`：Xcode 构建命令、成功摘要和增量复核。
- `10-diagnostic-provider-final-filtered.log`、`20-native-tab-final-filtered.log`、`60-after-review-native-tab-filtered.log`：Provider 安装、Performance API 和快照摘要。
- `10-diagnostic-provider-final.png`、`20-native-tab-final.png`、`60-after-review-native-tab.png`：Page/Native Tab 运行截图。

## HarmonyOS

- `00-assemble-app.log`、`80-final-assemble-app.log`：hvigor App 构建输出。
- `80-final-monitoring.log`：清空 HILOG 后最终 Page → Native Tabs → Settings/Home 日志，含 Provider snapshot、UUID/view/load 前缀、Bundle/release/sequence/SHA 前缀。
- `80-final-tabs.jpeg`、`81-final-settings.jpeg`、`60-after-review-index-layout.json`：运行截图和 UI tree。
- `80-final-crash-markers.log`：最终 crash marker 筛选结果，为空。

## 总报告

- [G1 验收报告](../g1-acceptance-report-2026-09-15.md)
- [执行记录](../g1-execution-log-2026-09-15.md)
- [工作流结果](../../../.workflow/lynx-g1-monitoring-acceptance-2026-09-15/)
