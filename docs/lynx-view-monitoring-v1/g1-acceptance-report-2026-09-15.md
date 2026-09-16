# Lynx 4.1 G1 三端性能监控验收报告

日期：2026-09-15  
仓库：`/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota`  
分支：`codex/lynx-view-monitoring-v1`  
基线：`main@e9ff9ee299d9cd786ad532a46f99a48988ab68ed`

## 最终结论

G1 已完成三端核心验收和发现问题后的修复。核心链路可以进入下一阶段研发：

- Android、iOS、HarmonyOS 都有显式 Debug-only 本地 Diagnostic Provider。
- Page 和 Native Tab 的加载、首屏、生命周期、显隐、销毁/重建和 PerformanceEntry 已在模拟器运行态验证；复核发现的身份、终态、脱敏和创建顺序问题已修复并重新回归。
- Bundle 的 `lynxAppId`、`bundleName`、release/sequence、实际字节 SHA-256、`viewId`、`loadId` 和 `processSessionId` 已能在代码或 Provider 快照中关联。
- Provider 调用不再从 HarmonyOS Lynx 回调同步进入；Android 的大错误 JSON 不再在调用侧先截断；iOS 初始化失败/超时会清队列并只释放一次 Provider。
- 本地 Provider 只保留有界内存，不调用 ARMS、Bugly、HTTP、Token、业务 Server 或任何云端服务。

`lynx.resource` 和 `lynx.js_error` 的三端公开回调接线、标准化投影、脱敏和字节预算已完成代码/契约覆盖，但当前官方/内置 Bundle 没有在本轮稳定产生这两个真实设备回调。因此这两个项目在矩阵中明确标为“未观察到”，没有把普通 SDK 日志、资源加载失败或页面启动当作事件通过。要把它们改成运行态 PASS，需要另提供可控的 G1 测试 Bundle。

## 这次验收解决了什么问题

### HarmonyOS P1 修复

审核指出的 HarmonyOS 高风险点已处理：

1. Provider 不再在 Lynx 回调栈同步执行；事件先进入 128 条 / 512 KiB 有界队列，再在下一轮事件循环串行交付。
2. 监控关闭或未配置时，性能和错误回调在解析/投影之前快速返回。
3. 安装时校验采样率、平台、每事件 Bundle 上下文、原始 JS frame、Performance/JS Error 必需能力和采样所有权。
4. `HostContext` 贯通宿主 App ID、构建号、Lynx Runtime 版本和进程 session，不再在客户端回调写死版本。
5. Provider 初始化最多等待 10 秒；失败、超时和关闭都会清空队列并幂等 dispose，迟到初始化结果不能复活实例。
6. View 到达首屏、失败或取消后，销毁不会额外追加错误的 `cancelled` 终态。
7. 增加 `onResourceLoaded` 到 `lynx.resource` 的映射和资源能力声明。

涉及文件：

- [LynxMonitor.ets](../../harmony/lynx_shell_kit/src/main/ets/monitoring/LynxMonitor.ets)
- [MonitorTypes.ets](../../harmony/lynx_shell_kit/src/main/ets/monitoring/MonitorTypes.ets)
- [LocalDiagnosticProvider.ets](../../harmony/lynx_shell_kit/src/main/ets/monitoring/LocalDiagnosticProvider.ets)
- [ShellLynxViewClient.ets](../../harmony/lynx_shell_kit/src/main/ets/client/ShellLynxViewClient.ets)
- [LynxContainer.ets](../../harmony/lynx_shell_kit/src/main/ets/pages/LynxContainer.ets)
- [LynxTabContainer.ets](../../harmony/lynx_shell_kit/src/main/ets/pages/LynxTabContainer.ets)
- [EntryAbility.ets](../../harmony/lynx_shell/src/main/ets/entryability/EntryAbility.ets)

### Android 大错误 JSON 修复

Android `captureError` 现在保留完整错误 JSON 进入 Provider worker，再由监控线程解析、脱敏和分别限制 message/rawStack/frame。输入预算和最终事件预算分离，避免错误 JSON 前部包装字段超过 24 KiB 时把尾部 `error_stack`、release/debugmetadata 一起截断。新增回归覆盖超过 24 KiB 且堆栈/debug key 位于后部的场景。

涉及文件：

- [LynxMonitor.kt](../../android/lynx-shell/src/main/java/com/example/lynxshell/monitoring/LynxMonitor.kt)
- [MonitorProjection.kt](../../android/lynx-shell/src/main/java/com/example/lynxshell/monitoring/MonitorProjection.kt)
- [MonitoringContractTest.kt](../../android/lynx-shell/src/test/kotlin/com/example/lynxshell/monitoring/MonitoringContractTest.kt)

### iOS Provider 清理和快照证据

iOS `LynxMonitorRuntime` 的初始化失败、超时、关闭和迟到 completion 统一走幂等清理。本轮还给 Debug Sample 增加显式 `--lynx-monitor-diagnostic` 开关和定时快照摘要日志，让系统日志能证明 Provider 实际收到事件。

涉及文件：

- [LynxMonitor.swift](../../ios/LynxShellKit/Monitoring/LynxMonitor.swift)
- [LynxMonitorDiagnosticProvider.swift](../../ios/LynxShellKit/Monitoring/LynxMonitorDiagnosticProvider.swift)
- [AppDelegate.swift](../../ios/LynxShellSample/App/AppDelegate.swift)

### 三端 Debug Sample 验收入口

- Android：从原生 Launcher 打开“Lynx 监控 G1 验收”，APP 内可打开 Page、Native Tab、资源测试页、刷新快照和把快照写入 logcat。
- iOS：Debug 启动参数 `--lynx-monitor-diagnostic` 安装内存 Provider；`--native-tab-demo` 直接进入 Native Tab。
- HarmonyOS：Want 参数 `lynx_monitor_local=1` 安装内存 Provider；本轮同时用 TEST-only mock + 内置 Bundle 保证离线可运行，未联网。

## 跨端验收矩阵

| 验收项 | Android API 35 | iOS 27.0 | HarmonyOS API 24 | 结论 |
| --- | --- | --- | --- | --- |
| Debug-only 本地 Provider 安装 | `local_diagnostic` ready | `ios.local_diagnostic` ready | `harmony.local_diagnostic` ready | 通过 |
| Page 加载/首屏/生命周期 | 修复后 APP 快照 25 条（完整流程曾导出 45 条） | 快照含 load/lifecycle | 快照含 load/lifecycle | 通过 |
| Native Tab Home/Settings | 两个 Tab + reload | Native Tab 截图/日志 | ArkUI Tabs + Settings/Home | 通过 |
| Tab 显隐/重建/关闭 | visible/hidden/destroyed 可见 | scope/lifecycle 可见 | create/release/Destroy 可见 | 通过 |
| `timing.onSetup` | logcat 可见 | Simulator log 可见 | HILOG 可见 `onPerformanceEvent` | 通过 |
| `onPerformanceEvent` → Provider | `lynx.performance` 2 条 | `lynx.performance` 1/2 条 | `lynx.performance` 1/2/4 条 | 通过 |
| FCP/Pipeline/阶段指标 | FCP/Pipeline 数值和缺失标记 | 投影代码已覆盖；本轮只导出类型计数 | 性能事件已到 Provider；本轮只导出类型计数 | 核心通过 |
| OTA release/sequence/SHA | verified + release/sequence/SHA | 代码 scope 已覆盖 | 代码 binding 已覆盖 | 代码/运行分层通过 |
| Direct Asset SHA | computed | 代码 scope 已覆盖 | 代码 binding 已覆盖 | 代码/运行分层通过 |
| `lynx.resource` 真实设备回调 | 未观察到 | 未观察到 | 未观察到 | 待专项 Bundle |
| `lynx.js_error` 真实设备回调 | 未观察到 | 未观察到 | 未观察到 | 待专项 Bundle |
| 资源/JS 投影、脱敏、预算 | JVM 契约覆盖 | Swift 代码/静态覆盖 | ArkTS 代码/静态覆盖 | 通过 |
| 128 条 / 512 KiB / 32 KiB 边界 | JVM 14/14，含大 JSON | 代码边界 | 代码边界 | 通过 |
| 初始化失败/10 秒超时/dispose-once | JVM 覆盖 | 代码边界 | 代码边界 | 通过 |
| crash marker | crash buffer 空 | 未匹配 crash marker | 未匹配 crash marker | 通过 |
| 厂商 SDK/HTTP/云端大盘 | 未接入 | 未接入 | 未接入 | G2 |

## Android 验收

### 环境和构建

- 设备：`LynxScreens_API35` / Android API 35 / `emulator-5554`。
- Gradle：8.11.1。
- JDK：Android Studio JDK 21。
- 初始完整流程 APK SHA-256：`ba81dd41f4b6bca58a579b2ea6bbcfc68b85c35538122eda3c5005ffe3789366`；审核修复后最终 APK SHA-256：`4102537227d501e96dc0a61f68fdfd57db03071e9b8fc93b82cf84f3fcbfd64d`。

执行：

```bash
cd android
GRADLE_BIN="$HOME/.gradle/wrapper/dists/gradle-8.11.1-bin/bpt9gzteqjrbo1mjrsomdt32c/gradle-8.11.1/bin/gradle"
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
  "$GRADLE_BIN" :lynx-shell:testDebugUnitTest :app:assembleDebug \
  --offline --no-daemon --console=plain
```

结果：整套 102 个用例 `0 failures / 0 errors / 3 skipped`；3 个 skipped 是既有外部 HTTP OTA 用例。监控契约套件为 `14 tests / 0 skipped / 0 failures / 0 errors`。

### APP 运行

Debug Sample 进入监控页后完成：

1. Page 首屏和返回监控页。
2. `video-demo.lynx.bundle` 资源/媒体页加载、SHA 计算和首屏。
3. Native Tab Home/Settings 切换。
4. Tab reload，旧 View 销毁后新 View 使用新的 `loadKind=reload`。
5. 回到监控页导出 45 条标准化事件到 logcat。

完整流程快照（包含资源页和 Tab reload）：

```text
Provider=local_diagnostic · monitorState=ready
queue=0/0 bytes · localEvents=45 · discardedLocal=0
handoff.recorded_locally=45
```

审核修复后的最小 Page → Native Tab 回归快照：

```text
Provider=local_diagnostic · monitorState=ready
queue=0/0 bytes · localEvents=25 · discardedLocal=0
counters={handoff.recorded_locally=25}
```

事件统计：

- Page：`view.load=8`、`view.lifecycle=8`、`lynx.performance=2`。
- Tab：`view.load=15`、`view.lifecycle=10`、`lynx.performance=2`。
- OTA Page：`bundleName=main.lynx.bundle`、`lynxAppId=10000001`、`releaseId=r20260901_0f1ter`、`releaseSequence=11`、`identityStatus=verified`。
- Direct Asset Page/Tab：SHA `computed`，可以区分直连资源和 OTA 身份。

证据：

- [46-snapshot-summary.md](g1-evidence/android/46-snapshot-summary.md)
- [46-full-snapshot-logcat.txt](g1-evidence/android/46-full-snapshot-logcat.txt)
- [46-monitor-ui.xml](g1-evidence/android/46-monitor-ui.xml)
- [14-page-tab-snapshot.png](g1-evidence/android/14-page-tab-snapshot.png)
- [44-native-tab.png](g1-evidence/android/44-native-tab.png)
- [45-native-tab-reload-logcat.txt](g1-evidence/android/45-native-tab-reload-logcat.txt)
- [63-after-review-runtime-filtered.log](g1-evidence/android/63-after-review-runtime-filtered.log)
- [65-after-review-final-monitor.png](g1-evidence/android/65-after-review-final-monitor.png)
- [63-after-review-crash.txt](g1-evidence/android/63-after-review-crash.txt)
- [30-page-crash.txt](g1-evidence/android/30-page-crash.txt)
- [42-resource-crash.txt](g1-evidence/android/42-resource-crash.txt)
- [44-native-tab-crash.txt](g1-evidence/android/44-native-tab-crash.txt)
- [45-native-tab-reload-crash.txt](g1-evidence/android/45-native-tab-reload-crash.txt)

### Android 审核后回归

独立复核发现 `home.lynx.bundle` 单独查 Manifest 会因两个 App ID 同名而失败，以及创建前 `visible` 事件顺序不正确。已分别修复为 `home + main` 组合解析和 `created → visible` 顺序，并重新构建、安装到 `emulator-5554` 验证。

- Gradle 构建成功，监控契约 `14/14`；最新 APK SHA-256 为 `4102537227d501e96dc0a61f68fdfd57db03071e9b8fc93b82cf84f3fcbfd64d`。
- APP 真实 Page、Native Tab 和监控页截图可见；最新快照 25 条，FCP/Pipeline、OTA release/SHA、Tab view/load 身份和 `created` 后 `visible` 均可读。
- 最新运行日志见 [63-after-review-monitor-summary.log](g1-evidence/android/63-after-review-monitor-summary.log)，监控页截图见 [65-after-review-final-monitor.png](g1-evidence/android/65-after-review-final-monitor.png)，crash buffer 见 [63-after-review-crash.txt](g1-evidence/android/63-after-review-crash.txt)。
- 最终 Gradle 输出见 [61-after-monitor-page-fix-gradle.log](g1-evidence/android/61-after-monitor-page-fix-gradle.log)，该次包含修复后 14/14 监控契约测试。

## iOS 验收

### 环境和构建

- 设备：iPhone 18 Pro Max Simulator / iOS 27.0。
- UDID：`2E98C9AA-9D32-4EEC-9A2E-E83BD90EDD6C`。
- Xcode：27.0 (27A266a)。
- 原指定 iPhone 16 Pro 不存在，退出码 70；未修改工程伪造该设备。
- 使用 iPhone 17 目标编译，临时命令行覆盖 `IPHONEOS_DEPLOYMENT_TARGET=15.0` 和 `-Wno-error=unused-result`，没有改 Pods 源码。

结果：`** BUILD SUCCEEDED **`，`ios_build_rc=0`；静态门禁 `113 PASS / 0 WARN / 0 FAIL`。

### Page/Native Tab 运行

Page 启动：

```text
[LynxMonitor] 本地诊断 Provider 安装结果：initializing
[LynxMonitor] snapshot provider=ios.local_diagnostic;state=ready;events=6;types=lynx.performance=1,view.lifecycle=1,view.load=4
[LynxMonitor] snapshot provider=ios.local_diagnostic;state=ready;events=7;types=lynx.performance=1,view.lifecycle=2,view.load=4
```

Native Tab 启动：

```text
[LynxMonitor] 本地诊断 Provider 安装结果：initializing
call jsmodule:GlobalEventEmitter.emit.lynx.performance.timing.onSetup
call jsmodule:GlobalEventEmitter.emit.lynx.performance.onPerformanceEvent
[LynxMonitor] snapshot provider=ios.local_diagnostic;state=ready;events=9;types=lynx.performance=2,monitor.diagnostic=1,view.lifecycle=2,view.load=4
```

证据：

- [10-diagnostic-provider-final.png](g1-evidence/ios/10-diagnostic-provider-final.png)
- [10-diagnostic-provider-final-filtered.log](g1-evidence/ios/10-diagnostic-provider-final-filtered.log)
- [20-native-tab-final.png](g1-evidence/ios/20-native-tab-final.png)
- [20-native-tab-final-filtered.log](g1-evidence/ios/20-native-tab-final-filtered.log)
- [60-after-review-native-tab.png](g1-evidence/ios/60-after-review-native-tab.png)
- [50-final-xcodebuild-summary.log](g1-evidence/ios/50-final-xcodebuild-summary.log)
- [60-after-review-native-tab-filtered.log](g1-evidence/ios/60-after-review-native-tab-filtered.log)
- [60-after-review-xcodebuild.log](g1-evidence/ios/60-after-review-xcodebuild.log)
- [00-static-check-final.log](g1-evidence/ios/00-static-check-final.log)

系统日志中没有匹配到 `JSCRASH`、`CPPCRASH`、`SIGABRT` 或 `SIGSEGV`。当前 XCUITest result bundle 曾出现 `totalTestCount=0 / result=unknown`，因此本报告不把那次命令算作 UI 测试通过；本轮 iOS 结论基于 simctl 安装、启动、截图和运行日志。

## HarmonyOS 验收

### 环境和构建

- 设备：DevEco Pura 90 Emulator。
- HarmonyOS API：24。
- HDC：`127.0.0.1:5557`。
- 包名：`com.example.lynxshell`。
- HAP：`harmony/lynx_shell/build/default/outputs/default/app/lynx_shell-default.hap`。

执行：

```bash
cd harmony
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
assembleApp --no-daemon
```

结果：主要回归 `BUILD SUCCESSFUL in 6 s 809 ms`，最后一次 frame 脱敏安全校验 `BUILD SUCCESSFUL in 6 s 391 ms`，退出码均为 0；静态门禁 `95 pass / 0 warn / 0 fail`。构建后 `harmony/lynx_shell_kit/BuildProfile.ets` 已恢复仓库原始 debug/true，未留下构建改写。

### HDC 运行

本轮先清空 HILOG，再显式启动：

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
"$HDC" -t 127.0.0.1:5557 install -r harmony/lynx_shell/build/default/outputs/default/app/lynx_shell-default.hap
"$HDC" -t 127.0.0.1:5557 shell hilog -r
"$HDC" -t 127.0.0.1:5557 shell \
  'aa start --ps lynx_monitor_local 1 --ps lynx_ota_mock 1 \
  --ps lynx_ota_api_base_url https://mock.invalid \
  -a EntryAbility -b com.example.lynxshell -W'
```

运行结果：

```text
[LynxHarmonyShell] LynxMonitor init state=ready
[LynxHarmonyShell] monitor_snapshot provider=harmony.local_diagnostic;ready=true;events=0;types=none;latest=none;view=none;load=none;container=none;bundle=none;release=none;sequence=none;sha=none
call jsmodule:GlobalEventEmitter.emit.lynx.performance.onPerformanceEvent
[LynxHarmonyShell] monitor_snapshot provider=harmony.local_diagnostic;ready=true;events=7;types=view.load=4,view.lifecycle=2,lynx.performance=1;latest=lynx.performance;view=309017c8;load=98a9dec7;container=page;bundle=home.lynx.bundle;release=mock-ota-v1;sequence=1;sha=318a7f52cd98
LynxShell release
LynxShell Destroy
[LynxHarmonyShell] monitor_snapshot provider=harmony.local_diagnostic;ready=true;events=9;types=view.load=4,view.lifecycle=4,lynx.performance=1;latest=view.lifecycle;view=309017c8;load=98a9dec7;container=page;bundle=home.lynx.bundle;release=mock-ota-v1;sequence=1;sha=318a7f52cd98
call jsmodule:GlobalEventEmitter.emit.lynx.performance.onPerformanceEvent
[LynxHarmonyShell] monitor_snapshot provider=harmony.local_diagnostic;ready=true;events=15;types=view.load=7,view.lifecycle=6,lynx.performance=2;latest=lynx.performance;view=21501858;load=6d99a8a0;container=tab;bundle=main.lynx.bundle;release=none;sequence=none;sha=none
call jsmodule:GlobalEventEmitter.emit.lynx.performance.onPerformanceEvent
call jsmodule:GlobalEventEmitter.emit.lynx.performance.onPerformanceEvent
[LynxHarmonyShell] monitor_snapshot provider=harmony.local_diagnostic;ready=true;events=22;types=view.load=10,view.lifecycle=8,lynx.performance=4;latest=lynx.performance;view=16b0a8f2;load=b721d99a;container=tab;bundle=main.lynx.bundle;release=none;sequence=none;sha=none
```

证据：

- [80-final-monitoring.log](g1-evidence/harmony/80-final-monitoring.log)
- [80-final-tabs.jpeg](g1-evidence/harmony/80-final-tabs.jpeg)
- [81-final-settings.jpeg](g1-evidence/harmony/81-final-settings.jpeg)
- [60-after-review-index-layout.json](g1-evidence/harmony/60-after-review-index-layout.json)
- [80-final-crash-markers.log](g1-evidence/harmony/80-final-crash-markers.log)
- [90-final-assemble-app.log](g1-evidence/90-final-assemble-app.log)

## 独立复核与修复闭环

复核 Agent 给出 `REQUEST CHANGES`，没有 P0。已落实的 P1 修复如下：

- HarmonyOS：UUID v4、failed 状态停止采集、JS 错误 URL/Token/Cookie 脱敏、`debugmetadata` frame 提取、load terminal 幂等、releaseSequence 透传、direct asset Bundle 名称补齐；静态检查和 HAP/模拟器回归再次通过。
- Android：创建前不发送 visible；监控页用唯一 Manifest 组合打开 Page；Gradle 14/14 和 API 35 Page/Tab 回归再次通过。
- iOS：普通后台 `file:line:column` 堆栈解析补齐；增量 xcodebuild 和 Native Tab/Provider snapshot 回归再次通过。

仍保留一个平台边界：HarmonyOS G1 公共队列在下一轮事件循环串行排空，当前本地 Provider 是轻量内存实现；未来厂商 SDK 若存在慢调用，必须在具体 Provider 内使用 HarmonyOS taskpool/Worker 隔离。当前没有把这一点包装成厂商线程隔离已经完成。

复核结论调整为“G1 核心链路通过，Resource/JS Error 运行态明确未观察”；真实资源/JS 错误和慢 Provider 线程隔离需要专用测试 Bundle/厂商 Provider 才能继续验收。

## 验证命令汇总

```bash
# Android/iOS 静态门禁
python3 scripts/static_check_android_ios.py --quiet
# 结果：113 PASS, 0 WARN, 0 FAIL

# Harmony 静态门禁
python3 harmony/scripts/check_harmony_shell.py --quiet
# 结果：95 pass, 0 warn, 0 fail

# Android 监控契约结果
python3 - <<'PY'
import xml.etree.ElementTree as ET
root = ET.parse('android/lynx-shell/build/test-results/testDebugUnitTest/TEST-com.example.lynxshell.monitoring.MonitoringContractTest.xml').getroot()
print(root.attrib)
PY
# tests=14, skipped=0, failures=0, errors=0

# 代码空白/冲突检查
git diff --check
```

静态、单测、构建、运行、Provider snapshot 和 crash marker 的证据分别保存在平台目录，没有用某一层结果替代另一层结果。

最终静态和工作流校验日志：[90-final-static-android-ios.log](g1-evidence/90-final-static-android-ios.log)、[90-final-static-harmony.log](g1-evidence/90-final-static-harmony.log)、[90-final-workflow-verify.log](g1-evidence/90-final-workflow-verify.log)。三项退出码均为 0，`git diff --check` 也为 0。

## 证据目录

```text
docs/lynx-view-monitoring-v1/
├── g1-acceptance-report-2026-09-15.md
├── g1-execution-log-2026-09-15.md
└── g1-evidence/
    ├── android/
    ├── ios/
    └── harmony/
```

执行记录索引：[g1-execution-log-2026-09-15.md](g1-execution-log-2026-09-15.md)。

证据文件索引：[g1-evidence/README.md](g1-evidence/README.md)。

## 剩余边界和下一步

1. **可控 JS 错误 Bundle**：增加一个明确触发 background/main-thread JS 错误回调的测试 Bundle，在三端模拟器重跑 `onReceivedError/receivedError → lynx.js_error → Provider snapshot`。
2. **可控资源 Bundle**：确认 Lynx 4.1 各平台公开 `onResourceLoaded` 的触发条件，增加稳定资源成功/失败样本；不能用普通图片下载日志替代。
3. **厂商 Provider（G2）**：确定 ARMS、Bugly 或其他 SDK 后，仅新增对应平台适配器，接入真实初始化、异步上报、重试、flush、离线有界缓存和厂商验收回执；公共 LynxView 监控核心不绑定厂商。
4. **线上错误还原（G2）**：把 Bundle SHA/release/debug key 与构建产物、Source Map/PrimJS Debug Info 建立发行环境索引，再做线上异常回放和源码行号验收。
5. **设备范围**：补真机、签名包、低磁盘、进程强杀/断电恢复和生产配置验证。

本轮没有提交或推送代码，工作树保留原有用户改动和本次 G1 改动，方便你审阅后决定下一步交付方式。
