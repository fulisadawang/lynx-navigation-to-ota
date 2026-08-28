# Packet: android-code-map

## Result

Android 已有一条稳定的 OTA 主链：`Application.onCreate/onForeground -> full latest-bundle-list -> OtaSdk/ReleaseTransaction -> current`；Activity 单独打开走 `resolveCurrent -> embedded -> ensureBundleReady`，Native Tab 只走 `resolveCurrent`，因此切 Tab 不联网。内置资源由 `EmbeddedBundleRegistry` 按 `(lynxAppId, bundleName)` 精确匹配并直接从 APK AssetManager 读取，不复制到 OTA store。

## Confirmed gaps

- Sample 的 Tab 与部分 demo 入口仍显式写死 `10000001`；运行时不能从 bundle 文件名推断 appId，这是正确约束，但应把 demo identity 收敛到 registry/API 返回的完整 identity。
- Android 没有 iOS 的 candidate/trial/healthy-confirm/discard/recover 状态机。
- Android `LynxShellActivity` 的 Lynx 首屏 `onReceivedError` 目前只通知转场协调器，没有进入 OTA recovery。
- Android rollback 重新 prepare 后的来源处理需要区分恢复到 previous remote 与恢复到 embedded baseline，不能统一标成 `rollback_fallback`。
- Android `LynxOtaRuntime` 直接构造 SDK，生命周期和真实 UI 层缺少可替换 API/runtime、请求计数和 fault hook。

## Evidence

- `android/lynx-shell/src/main/kotlin/com/example/lynxshell/ota/LynxOtaRuntime.kt`
- `android/lynx-shell/src/main/java/com/example/lynxshell/container/LynxShellActivity.kt`
- `android/lynx-shell/src/main/java/com/example/lynxshell/tab/LynxTabFragment.kt`
- `android/lynx-shell/src/main/kotlin/com/example/lynxshell/ota/EmbeddedBundleRegistry.kt`
- iOS baseline: `ios/LynxShellKit/OTA/LynxOtaRuntime.swift` and `ios/OtaIOSSDK/Sources/OtaIOSSDK/CanonicalOtaStore.swift`

## Decision

主线程实现最小、可选的 Android candidate state machine，并补齐 first-screen recovery/source provenance；Tab 继续保持 cache-only，不能为了“对齐 iOS”把网络请求塞入 Fragment。
