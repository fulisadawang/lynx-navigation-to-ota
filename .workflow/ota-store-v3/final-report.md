# Final Report: OTA Store v3 三端真正增量更新与运行态验收

## Outcome

P0–P4 已完成：测试用例、100 Bundle Golden Fixture、本地 OTA Server、iOS、Android 和 HarmonyOS
Store v3 实现及各自的运行态截图 HTML 均已落盘。P4 审计将未覆盖的物理设备、低磁盘和独立进程
故障注入明确保留为 BLOCKED，不把它们升级成通过。

## Accepted Results

- 三端使用完整 Manifest 快照；客户端按 App ID 作用域的 SHA-256 CAS 对象复用。
- iOS、Android、HarmonyOS 均完成 V1 100 个 Bundle → V2 只变 050 的运行态证据。
- Native Tab 普通切换不请求 OTA；主动刷新完成后才重读 current；路由/页面保留各自已提交快照。
- HarmonyOS 使用 current/previous，不加入 candidate/trial。
- iOS：54/54 Swift 单测、XCUITest 默认 7/0/3（通过/失败/跳过），本地真实 OTA smoke 1/0/0。
- Android：47/47 JVM 单测通过，API 35 模拟器完成 V1/V2、Tab、冷启动、ETag 和磁盘 Inspector 验收。
- HarmonyOS：89/89 静态检查通过，DevEco 模拟器完成 V1/V2、ArkUI Tabs、HDC force-stop、故障矩阵和磁盘 Inspector 验收。

## Rejected Results

- 不把历史 HarmonyOS Store v2/Mock Source 报告当作当前 v3 证据。
- 不把外部 OTA Server 不可访问、物理真机、低磁盘和独立进程 crash 未验证项写成通过。

## Conflicts Resolved

- HarmonyOS 静态门禁已从旧 ReleaseTransaction v2 断言切换为实际 ContentAddressedOtaStore v3 断言。
- Android Gradle 静态检查的字符串插值括号误报已消除，没有改变运行时 token 注入语义。

## Verification Evidence

- docs/ios-ota-store-v3-test-report.html
- docs/android-ota-store-v3-test-report.html
- docs/harmony-ota-store-v3-test-report.html
- docs/lynx-ota-store-v3-test-cases.md
- .workflow/ota-store-v3/results/P4-final-audit.md

## Remaining Risks

- 三端生产 CDN/TLS、签名包、物理设备和独立进程故障注入仍需单独验收。

## Reusable Follow-up

- 发布前继续执行 scripts/ota-store-v3/local-server.mjs 的 404、bad-sha、bad-size、disconnect 和 metrics
  场景；在服务端正式支持 Harmony 平台后移除 `serverPlatform=android` 兼容值，并补做物理设备、签名包、真实 ENOSPC、断电和生产 CDN/TLS 验收。
