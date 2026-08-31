# P0 Result — 当前代码与资产映射

> 历史说明：本文件记录 P0 立项时的 Store v2 基线调查。P1–P3 已按该基线完成 v3 实现；下方“当前”措辞只描述实现前事实，不代表最终运行态。

## 结论

当前 Android、iOS、HarmonyOS 都是 Store v2：完整 Release Manifest + `appId/releaseId` 自包含目录 + `current/previous` 指针 + 进程内 Release lease。尚未实现 CAS 对象库。

100 个 Bundle 中只有 1 个变化时，当前实际行为是：

- 服务端/发布端发送完整快照，`changedBundles` 是历史字段名，不是纯 delta；Playground 发布脚本先合并旧 Bundle 再发布完整列表。
- 网络层在旧 current 的 `bundlePath + SHA` 命中时只下载变化 Bundle。
- Android、HarmonyOS 会把未变化 Bundle 复制到新 staging；iOS 下载阶段复用旧路径，但 Canonical Store stage 仍复制完整集合。
- 稳定磁盘至少保留完整 `current + previous`；candidate、lease、staging 会进一步扩大峰值。
- 路由参数仍是逻辑 `appId + bundleName`，Native Tab 严格 cache-only；当前没有 session 级 OTA Manifest 快照，普通页面可能在版本切换前后分别解析 current。

## 关键调用链

| 平台 | 普通页面 | Native Tab | Store 事务 |
|---|---|---|---|
| Android | `LynxShellActivity` → `LynxOtaRuntime.prepare/resolvePage` | `LynxTabFragment` → `resolveCurrent` | `OtaSdk` → `ReleaseTransaction` |
| iOS | `LynxContainerViewController` → `LynxOtaRuntime` | `LynxTabViewController` → `resolveCurrent` | `OtaSDK` → `ReleaseTransaction` → `CanonicalOtaStore` |
| HarmonyOS | `LynxContainer` → `PageBundleRuntime.prepare` | `LynxTabContainer` → `resolveCurrent` | `LynxOtaRuntime` → `ReleaseTransaction` |

页面解析后持有 Release lease，避免 prune/delete 删除仍在使用的文件；但 lease 保护的是完整 Release 目录，不是 CAS Object 引用。

## 精确证据

- Android 旧 Bundle 命中后仍执行 `copyAndHash`：[ReleaseTransaction.kt:998](/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/android/lynx-shell/src/main/kotlin/com/ota/android/sdk/ReleaseTransaction.kt:998)、[ReleaseTransaction.kt:1077](/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/android/lynx-shell/src/main/kotlin/com/ota/android/sdk/ReleaseTransaction.kt:1077)。
- iOS 下载阶段复用旧路径：[OtaSDK.swift:945](/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/ios/OtaIOSSDK/Sources/OtaIOSSDK/OtaSDK.swift:945)；stage 阶段全量 `copyItem`：[CanonicalOtaStore.swift:210](/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/ios/OtaIOSSDK/Sources/OtaIOSSDK/CanonicalOtaStore.swift:210)。
- HarmonyOS 明确把 `changedBundles` 当完整快照，并对 SHA 相同文件执行 `copyFileSync`：[ReleaseTransaction.ets:95](/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/harmony/lynx_shell_kit/src/main/ets/ota/ReleaseTransaction.ets:95)、[ReleaseTransaction.ets:140](/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/harmony/lynx_shell_kit/src/main/ets/ota/ReleaseTransaction.ets:140)。
- 发布脚本把旧清单合并为完整 `completeBundles`：[publish-ota-bundle.mjs:214](/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/playground/scripts/publish-ota-bundle.mjs:214)、[publish-ota-bundle.mjs:268](/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/playground/scripts/publish-ota-bundle.mjs:268)。

## 本地资产盘点

- Playground 有构建和真实 OSS/Admin 发布脚本，但没有本仓库内可直接启动的 `LynxOtaServer`、Docker Compose 或 fixture server。
- 三端都有 embedded Manifest，可复用为独立 embedded baseline；Bundle bytes 从 APK/App Bundle/rawfile 直接读取。
- 三端都有只读 Storage Diagnostics/Inspector，可扩展显示 v3 object、Manifest、lease 和 GC 引用。
- 当前 Android 有 downloaded/copied 统计，iOS 有 downloaded/reused 统计，Harmony 没有跨端一致的 CAS 计数契约。

## P1 iOS 边界

P1 只改 `CanonicalOtaStore.swift`、`OtaSDK.swift`、`OtaStorageDiagnostics.swift` 及 iOS SDK 测试，先把完整 Manifest + App-scoped CAS + object ingest/GC/metrics 做稳定。Router、UIViewController、Native Tab 只消费 `PreparedOtaBundle + lease`，不感知 object 物理路径；随后再接入 NavigationSnapshot。

## 约束与风险

- App ID 必须继续物理隔离；不跨 App ID 共享对象。
- 真实服务端不在当前仓库，本地 fixture server 是本轮必要新增能力。
- HarmonyOS `fsync/rename/atomic replace` 的目标 SDK 能力需要在实现和真机阶段验证。
- Demo 可卸载重装切换 schema，不做 Store v2 原地迁移。
