# Android verification result

## Automated

- `bash scripts/ota-fault/run.sh --platform android --tier sdk --case all` — PASS。
- `:lynx-shell:testDebugUnitTest` — 26 tests, 0 failure, 0 error。
- `:app:assembleDebug` — BUILD SUCCESSFUL。
- `:app:installDebug` — installed on 1 Android device。
- `python3 scripts/static_check_android_ios.py --quiet` — 111 PASS / 0 WARN / 0 FAIL。
- HTML self-check — 19 case IDs, interactive script present, no external assets, no token。
- exact secret scan over repository and Obsidian — PASS；凭证未进入产物。

## Real service

- TEST / capp / android latest-bundle-list returned JSON with two identities:
  `10000001 -> r20260823_qc8ffc (28)` and `10000002 -> r20260806_dhax5q (12)`。
- API base URL was used only at runtime; token was read from the ignored local build property and was not printed or persisted in workflow/report。

## Android device

- Device: IN2010, Android 13, SDK 33, USB, package `com.example.lynxshell.debug`。
- Clean-store first open screenshot: `10000001 / r20260823_qc8ffc / 内置 baseline / main.lynx.bundle`。
- After startup full sync and next cold start: `10000001 / r20260823_qc8ffc / OTA current / main.lynx.bundle`。
- `run-as` confirmed `embedded_copy=absent` and canonical state present。
- Native Tab Home screenshot matched standalone identity; Settings tab rendered; round trip remained in `NativeTabDemoActivity`。
- Startup plus explicit refresh produced full-sync log count `2`; two Tab instances were rendered twice each (main Bundle log count `4`)。
- Debug 一次性首屏故障注入后，真机页面显示 `10000001 / r20260823_qc8ffc / 回滚 fallback / main.lynx.bundle`；10000001 downloaded current 被删除且没有 embedded 沙盒副本。

## Boundaries

- The real service currently has no releaseId delta above the embedded baseline, so “new V2 release after publish” is not claimed.
- Android instrumentation runner/Espresso/UIAutomator is not configured; screen claims are adb screenshots/logs/run-as plus visual inspection.
- Real embedded fallback after injected first-screen failure is device PASS；两个不同 remote release 的 previous rollback + rollback commit 后 force-stop 仍待专门 fixture/hook。
