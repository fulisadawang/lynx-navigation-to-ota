# Lynx 4.1 G1 三端验收执行记录

日期：2026-09-15  
仓库：`/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota`  
分支：`codex/lynx-view-monitoring-v1`  
基线：`main@e9ff9ee`  
范围：LynxView 性能、加载、生命周期、Bundle 身份、资源/JS 错误接线、Provider 队列和关闭语义。  
排除：ARMS、Bugly、其他厂商 SDK、HTTP/Token/业务 Server、云端大盘、生产 source map 服务、G2。

## 记录规则

- 所有平台先做静态/构建，再做模拟器安装和运行态操作。
- `DiagnosticProvider`、`LynxMonitorDiagnosticProvider`、`LocalDiagnosticProvider` 都只保存有界内存，不联网。
- `onSetup` 和 `onPerformanceEvent` 只证明 Lynx Performance API 回调进入宿主；只有 Provider snapshot 才能证明标准事件被本地 Provider 接收。
- 资源和 JS 错误没有稳定公开 fixture 时，记录“未观察到”，不把普通 SDK 日志、页面启动或加载失败当作对应事件。
- 日志只保留脱敏摘要、事件计数和必要字段；没有写入 Token、Cookie、业务请求正文或凭据。

## 执行时间线

### 12:33–12:40：创建动态工作流

创建：`.workflow/lynx-g1-monitoring-acceptance-2026-09-15/`。

- `plan.md`：成功标准是三端构建、显式本地 Provider、Page/Native Tab、快照、队列/关闭和报告。
- `orchestration.md`：P1 Android、P2 iOS、P3 HarmonyOS、P4 报告整合。
- 用户已经授权本次构建、模拟器运行、必要修复、报告和 Obsidian 写入；没有授权提交/推送，因此本轮未执行 Git commit/push。

### Android

设备：`LynxScreens_API35`，API 35，ADB serial `emulator-5554`。

```bash
cd /Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/android
GRADLE_BIN="$HOME/.gradle/wrapper/dists/gradle-8.11.1-bin/bpt9gzteqjrbo1mjrsomdt32c/gradle-8.11.1/bin/gradle"
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
  "$GRADLE_BIN" :lynx-shell:testDebugUnitTest :app:assembleDebug \
  --offline --no-daemon --console=plain
adb -s emulator-5554 install -r --no-streaming app/build/outputs/apk/debug/app-debug.apk
adb -s emulator-5554 shell am force-stop com.example.lynxshell.debug
adb -s emulator-5554 shell am start -W \
  -n com.example.lynxshell.debug/com.example.lynxshell.sample.MainActivity \
  --ez lynx_shell.open_playground true
```

APP 操作：打开“Lynx 监控 G1 验收”→ Page → 返回 → Native Tab → Home/Settings → reload → 资源/媒体 Page → 返回监控页 → “把当前快照写入 logcat”。

结果：

- Gradle：`BUILD SUCCESSFUL`；整套 102 个用例 0 failures、0 errors、3 个既有外部 HTTP 用例 skipped；监控契约 14/14。
- Provider：`local_diagnostic`，`ready`，45 条标准事件，队列 `0/0`，本地丢弃 `0`。
- Page/Tab：有 `view.load`、`view.lifecycle`、`lynx.performance`；Page OTA 身份含 verified release/sequence/SHA；Tab reload 生成新 view/load 身份。
- 资源/JS 错误：真实回调未观察到；资源映射、JS 错误 JSON/脱敏/debug key/大 JSON 由契约测试覆盖。
- crash buffer：Page、资源页、Native Tab、reload 均为空。

证据目录：`docs/lynx-view-monitoring-v1/g1-evidence/android/`。  
关键文件：[46-snapshot-summary.md](g1-evidence/android/46-snapshot-summary.md)、[46-full-snapshot-logcat.txt](g1-evidence/android/46-full-snapshot-logcat.txt)、[50-final-gradle.log](g1-evidence/android/50-final-gradle.log)。

### iOS

设备：iPhone 18 Pro Max Simulator，iOS 27.0，UDID `2E98C9AA-9D32-4EEC-9A2E-E83BD90EDD6C`。

仓库指定的 iPhone 16 Pro 不存在，原始目标退出码 70；没有修改工程伪造目标，改用当前可用 iPhone 17 目标编译，再安装到已启动的 iPhone 18 Pro Max。

```bash
cd /Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/ios
pod install --no-repo-update
cd ..
xcodebuild -workspace ios/LynxShell.xcworkspace -scheme LynxShell -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  -derivedDataPath /tmp/lynx-g1-ios-derived-final CODE_SIGNING_ALLOWED=NO \
  IPHONEOS_DEPLOYMENT_TARGET=15.0 \
  OTHER_CPLUSPLUSFLAGS='$(inherited) -Wno-error=unused-result' build
xcrun simctl install 2E98C9AA-9D32-4EEC-9A2E-E83BD90EDD6C \
  /tmp/lynx-g1-ios-derived-final/Build/Products/Debug-iphonesimulator/LynxShell.app
xcrun simctl launch 2E98C9AA-9D32-4EEC-9A2E-E83BD90EDD6C \
  com.example.lynxshell --lynx-monitor-diagnostic
```

随后重新启动：

```bash
xcrun simctl launch 2E98C9AA-9D32-4EEC-9A2E-E83BD90EDD6C \
  com.example.lynxshell --lynx-monitor-diagnostic --native-tab-demo
```

结果：

- `xcodebuild`：`** BUILD SUCCEEDED **`，退出码 0。
- 静态检查：`113 PASS, 0 WARN, 0 FAIL`。
- Page：本地 Provider `ready`，快照由 6 增长到 7，含 performance/lifecycle/load。
- Native Tab：快照由 4 增长到 9，含 `lynx.performance=2`、`view.lifecycle=2`、`view.load=4` 和 1 条诊断事件。
- crash：日志未匹配 JSCRASH/CPPCRASH/SIGABRT/SIGSEGV 等标记。
- 资源/JS 错误：本轮内置 Bundle 未稳定触发真实回调，代码接线已保留。

证据目录：`docs/lynx-view-monitoring-v1/g1-evidence/ios/`。  
关键文件：[20-native-tab-final-filtered.log](g1-evidence/ios/20-native-tab-final-filtered.log)、[20-native-tab-final.png](g1-evidence/ios/20-native-tab-final.png)、[50-final-xcodebuild-summary.log](g1-evidence/ios/50-final-xcodebuild-summary.log)。

### HarmonyOS

设备：DevEco Pura 90 Emulator，HarmonyOS API 24，HDC `127.0.0.1:5557`。

```bash
cd /Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/harmony
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
assembleApp --no-daemon
cd ..
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
"$HDC" -t 127.0.0.1:5557 install -r \
  harmony/lynx_shell/build/default/outputs/default/app/lynx_shell-default.hap
"$HDC" -t 127.0.0.1:5557 shell hilog -r
"$HDC" -t 127.0.0.1:5557 shell \
  'aa start --ps lynx_monitor_local 1 --ps lynx_ota_mock 1 \
  --ps lynx_ota_api_base_url https://mock.invalid \
  -a EntryAbility -b com.example.lynxshell -W'
```

APP 操作：内置 Page → 返回原生 Index → 点击“打开原生 Tabs 承载 Demo”→ Settings → Home；清空 HILOG 后重新执行该最短链路并保存 snapshot/HILOG/截图。

结果：

- 静态门禁：`95 pass, 0 warn, 0 fail`。
- HAP：`BUILD SUCCESSFUL in 6 s 629 ms`，退出码 0；构建后 `BuildProfile.ets` 已恢复为仓库原始 debug/true。
- Provider：`harmony.local_diagnostic`，`ready`；快照从 0 增长到 22。
- 关键类型：`view.load=10`、`view.lifecycle=8`、`lynx.performance=4`。
- Page/Tab 重建可见新的 `LynxShell create/release/Destroy`；无 JSCRASH、CPPCRASH、SIGSEGV、SIGABRT、FATAL crash marker。
- 资源/JS 错误：现有内置 Bundle 未稳定触发；映射和能力声明已补齐。

证据目录：`docs/lynx-view-monitoring-v1/g1-evidence/harmony/`。  
关键文件：[50-clean-monitoring.log](g1-evidence/harmony/50-clean-monitoring.log)、[50-clean-native-tabs.jpeg](g1-evidence/harmony/50-clean-native-tabs.jpeg)、[51-clean-settings.jpeg](g1-evidence/harmony/51-clean-settings.jpeg)。

## 结论快照

| 平台 | 本地 Provider | Page/Tab | 性能 | 资源真实回调 | JS 错误真实回调 | 崩溃 marker |
| --- | --- | --- | --- | --- | --- | --- |
| Android | ready，45 条 | 通过 | 通过 | 未观察到 | 未观察到 | 空 |
| iOS | ready，4 → 9 条 | 通过 | 通过 | 未观察到 | 未观察到 | 未匹配 |
| HarmonyOS | ready，0 → 22 条 | 通过 | 通过 | 未观察到 | 未观察到 | 空 |

完整结论见：[g1-acceptance-report-2026-09-15.md](g1-acceptance-report-2026-09-15.md)。

## 21:10–21:27：独立复核、修复和二次回归

独立审核没有发现 P0，但指出以下 P1/P2：Harmony ID 不是 UUID、失败后仍可采集、错误文本缺少脱敏/debug key、终态竞态、releaseSequence 和 direct asset Bundle 名称缺失；Android 创建前误报 visible、验收页 `home` App ID 歧义；iOS 普通后台堆栈无法识别 line/column。

已执行修复：

- Harmony `MonitorUtils.ets` 用 `cryptoFramework.createRandom().generateRandomSync(16)` 生成 UUID v4；错误消息/堆栈移除 URL 查询、Token、Cookie、Bearer；从 `debugmetadata:<key>` 提取 frame 调试键；`LynxMonitor` 增加 idle/initializing/ready/failed/closed 状态，失败后停止采集；`firstContent/loadFailed/cancelled` 终态幂等；透传 releaseSequence；direct asset 记录 Bundle 名称。
- Android `LynxViewMonitor` 在真实 View attach/create 后再发首个 visible；监控验收页用 `home + main` 组合解析唯一 App ID。
- iOS `LynxMonitorSanitizer` 增加普通 `file:line:column` 解析；iOS Debug Provider 保持快照摘要日志。

二次静态和构建：

```bash
python3 harmony/scripts/check_harmony_shell.py --quiet
# 95 pass, 0 warn, 0 fail

python3 scripts/static_check_android_ios.py --quiet
# 113 PASS, 0 WARN, 0 FAIL

cd android
GRADLE_BIN="$HOME/.gradle/wrapper/dists/gradle-8.11.1-bin/bpt9gzteqjrbo1mjrsomdt32c/gradle-8.11.1/bin/gradle"
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
  "$GRADLE_BIN" :lynx-shell:testDebugUnitTest :app:assembleDebug \
  --offline --no-daemon --console=plain
# BUILD SUCCESSFUL；MonitoringContractTest 14/14

cd harmony
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
assembleApp --no-daemon
# BUILD SUCCESSFUL in 6 s 809 ms

cd ..
xcodebuild -quiet -workspace ios/LynxShell.xcworkspace -scheme LynxShell \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  -derivedDataPath /tmp/lynx-g1-ios-derived-final CODE_SIGNING_ALLOWED=NO \
  IPHONEOS_DEPLOYMENT_TARGET=15.0 \
  OTHER_CPLUSPLUSFLAGS='$(inherited) -Wno-error=unused-result' build
# BUILD SUCCEEDED；退出码 0
```

二次设备回归：

- Android `emulator-5554`：重新安装最终 APK，APP 监控页打开 Page/Native Tab，最新截图显示 `localEvents=25`、队列 `0/0`、`handoff.recorded_locally=25`；事件顺序为 Page `created` 后 `visible`。证据：[63-after-review-page-fixed.png](g1-evidence/android/63-after-review-page-fixed.png)、[64-after-review-native-tab-fixed.png](g1-evidence/android/64-after-review-native-tab-fixed.png)、[65-after-review-final-monitor.png](g1-evidence/android/65-after-review-final-monitor.png)、[63-after-review-monitor-summary.log](g1-evidence/android/63-after-review-monitor-summary.log)。
- iOS iPhone 18 Pro Max / iOS 27.0：重新安装最终构建，带 `--lynx-monitor-diagnostic --native-tab-demo`，快照 `events=9`、`lynx.performance=2`；证据：[60-after-review-native-tab-filtered.log](g1-evidence/ios/60-after-review-native-tab-filtered.log)、[60-after-review-native-tab.png](g1-evidence/ios/60-after-review-native-tab.png)。
- HarmonyOS Pura 90 / API 24：重新安装最终 HAP，清空 HILOG 后运行 Page → Native Tabs → Settings/Home，快照 `events=0 → 7 → 9 → 15 → 22`；最新摘要包含 UUID 前缀、container、Bundle 名称、release/sequence/SHA 前缀；证据：[80-final-monitoring.log](g1-evidence/harmony/80-final-monitoring.log)、[80-final-tabs.jpeg](g1-evidence/harmony/80-final-tabs.jpeg)、[81-final-settings.jpeg](g1-evidence/harmony/81-final-settings.jpeg)。

二次回归仍没有人为注入 JS 错误或资源回调；这两类保持“代码/契约通过，设备真实回调未观察”。

## 最终校验

```bash
python3 scripts/static_check_android_ios.py --quiet
# 113 PASS, 0 WARN, 0 FAIL
python3 harmony/scripts/check_harmony_shell.py --quiet
# 95 pass, 0 warn, 0 fail
python3 /Users/nieyutan/.codex/skills/codex-dynamic-workflows/scripts/verify_workflow.py \
  .workflow/lynx-g1-monitoring-acceptance-2026-09-15
# Workflow verification passed
git diff --check
# 无输出，退出码 0
```

校验日志：[90-final-static-android-ios.log](g1-evidence/90-final-static-android-ios.log)、[90-final-static-harmony.log](g1-evidence/90-final-static-harmony.log)、[90-final-workflow-verify.log](g1-evidence/90-final-workflow-verify.log)。

## 21:40：最终安全校验

补充 Harmony frame 文件字段脱敏后再次执行静态门禁和 `assembleApp`：静态 `95 pass / 0 warn / 0 fail`，构建 `BUILD SUCCESSFUL in 6 s 391 ms`，退出码 0；Android/iOS 静态门禁、工作流完整性和 `git diff --check` 仍为 0。最终构建日志：[90-final-assemble-app.log](g1-evidence/90-final-assemble-app.log)。
