# Android 手动查看入口

2026-10-09，用户要求安装到本机模拟器供自己点击。目标仅 `emulator-5554` / medium_phone；APK 为当前 `codex/bundle-loading-opt` 的优化 Debug 宿主，包名 `com.hugboga.custom.otae2e`。不清数据、未操作真机。

## 已安装的入口

App 默认进入「Bundle 加载优化 · 手动验收」，提供：小包、大包、Async 十脚本、查看 OTA Store。三夹具均走公开 `LynxRouter.open` → 普通原生 Page，不在 Launcher 内容中替换 Bundle。返回键回入口。

新的 App-only `BundleLoadingManualDemo` 使用上轮同 SHA 的 token-free 描述文件，经真实 sidecar stage + Store install，放入 `files/bundle-loading-manual-store`。每个页面返回真实 file、lease、sidecar，由原容器生命周期关闭；不复制到 APK assets、不改库加载优化、不重建 Fixture。

启用条件是 DEBUG、已有 device-E2E 构建和描述文件存在；显式 `lynx_shell.show_native_launcher=true` 仍进入原入口，避免干扰既有 instrumentation 宿主。手动 APK 的 App 入口增量不作为新的性能样本，原报告 baseline/optimized 的数字保留。

## 实际验证

- APK 构建成功并 `install -r` 安装，最终构建 11 秒，无依赖升级。
- Small、Large、Async 三页面均实际显示 READY，Native 严格接受各自 source.pageKey 和计算 payload。
- Large：payloadLength 3,145,728，checksum 1,009,422,673；Async：moduleCount 10，checksum 56,430。
- 三页面系统 Back 回原入口；Store 浏览器显示 App ID 10030071、current r20260421_002 (downloaded)、manifest valid，16 文件约 3.3 MB。
- 首次手动 READY 被拒绝，实际定位为 Bridge 解析默认 routeKey 是 assets URL；已显式传 `routeKey=path` 与描述的 case.path 对齐，不放松回执条件。Lynx 专项复核了最终修正，无新增阻断项。
- 这次是基础手点/返回验证，不补充十页并存、完整生命周期、RSS 或首屏性能统计。

截图在 evidence/manual；其中 routekey-red 保留首次拒绝，三个 ready 图保留修后实际页面。最终停在手动入口供用户操作。

## 后续安装

最终 APK：`android/app/build/outputs/apk/debug/app-debug.apk`。

```bash
adb -s emulator-5554 install -r android/app/build/outputs/apk/debug/app-debug.apk
adb -s emulator-5554 reverse tcp:18781 tcp:18781
```

App 数据保留时描述文件与已验证 Store 一并保留，重开无需临时 instrumentation。首次全新安装需提供这次的 `fixture-android-description.json` 到私有 files/bundle-loading-fixture.json，并保持本地资源服务 18781 可用；描述文件不含凭据。不要用旧 fixture-out 替换固定 fixture-final-out。
