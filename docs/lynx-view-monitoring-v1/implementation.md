# LynxView 监控 G1 实现说明

日期：2026-09-15
分支：codex/lynx-view-monitoring-v1
基线：main e9ff9ee（Lynx 4.1）

这次把设计落成了一个只负责 LynxView 观测和本地归档的 G1 实现。它不依赖业务 Server，不在手机端上传源码材料，也没有预先绑定 ARMS、Bugly 或其他第三方 SDK。后续选定厂商时只需要实现 Provider 和构建产物适配器，G1 的事件身份、队列、脱敏、SHA 和源码还原契约保持不变。

## 厂商上报接入备注

当前只保留可插拔的 `RuntimeProvider` 接口，没有选择或接入具体厂商。Android 的 `RuntimeProvider.record(event)`、iOS 的对应 Provider 入口以及 HarmonyOS 的对应 Provider 入口，都是统一的事件交付口；它们不是网络 URL，也不代表事件已经到达后台。

目前使用的 `DiagnosticProvider` / `LynxMonitorDiagnosticProvider` / `LocalDiagnosticProvider` 只用于本地验收，返回本地记录状态，不产生网络请求。后续确定 ARMS、Bugly 或其他平台后，新增独立的 `integration/monitoring/<provider>/` 适配器，由适配器调用厂商 SDK 或自定义 HTTP；厂商 SDK 或该适配器负责 URL、Token、异步发送、批量、重试和 `flush`。公共监控核心、Page、Tab 和 LynxView 接线不绑定任何厂商实现。

厂商确定后再开展 G2 接入和验收：先核对三端 SDK 能力及事件字段映射，再接入运行时 Provider 和构建产物上传 Provider，最后以厂商后台可查询、Bundle 身份可筛选、JS 堆栈可还原为完成标准。在此之前，不把 `RECORDED_LOCALLY` 或 `ACCEPTED_BY_SDK` 解释成服务端已收到。

## 已接通的运行链

Android、iOS、HarmonyOS 的 Page 和 Native Tab 都在真正创建 LynxView 的入口安装监听：

1. 容器创建前预留 viewId/loadId，并记录尝试中的 Bundle 来源。
2. OTA prepare 返回后冻结 releaseId、releaseSequence、sha256 和 Bundle 名称；直连 asset/HTTPS 在实际字节交给 Lynx 前计算一次 SHA。
3. LynxView 创建后接入性能、资源、加载和错误回调。
4. 回调只复制白名单标量和有限字符串，事件进入进程级有界队列。
5. Android/iOS 由监控专用串行执行器消费；HarmonyOS G1 使用下一轮事件循环串行排空，Provider.record 必须保持快速返回，未来慢 SDK 仍需在具体 Provider 内使用 taskpool/Worker 隔离。Provider 抛错或拒绝只产生诊断计数，不改变页面、OTA、回滚或转场。
6. 页面销毁前关闭 View scope、摘除监听和取消资源任务；关闭前已经入队的不可变事件仍保留原来的身份。

普通 Tab 显隐不会产生新的 viewId/loadId。原位 reload 没有官方逐事件关联键时，事件降级为 exact_view 并清空 loadId、loadKind、Bundle 归属，绝不按接收顺序或最新 OTA current 猜测。

## 宿主如何启用

监控不会在未配置 Provider 时偷偷启动。宿主必须在首个需要监控的 LynxView 创建前安装一个 Provider；G1 可以使用本地有界 Provider 验收，G2 再换成厂商适配器。

Android：

~~~kotlin
private lateinit var diagnosticProvider: DiagnosticProvider

override fun onCreate() {
    super.onCreate()
    diagnosticProvider = DiagnosticProvider()
    val result = LynxMonitor.install(
        this,
        MonitorConfig(
            provider = diagnosticProvider,
            performanceSampleRate = 1.0,
        ),
    )
    // result.state=initializing 表示监控初始化异步开始；页面加载不等待 Provider。
}

fun dumpLynxEvents(): List<MonitorEvent> = diagnosticProvider.snapshot()
~~~

如果已经用生产构建清单核实某些脚本的数字位置格式，可以通过 MonitorConfig.scriptPositionFormats 按 source-map key 登记 LINE_COLUMN 或 FUNCTION_PC；没有登记时保留 unknown 和原始堆栈。

iOS：

~~~swift
let diagnosticProvider = LynxMonitorDiagnosticProvider()
let result = LynxMonitor.install(
    .init(enabled: true, provider: diagnosticProvider, performanceSampleRate: 1)
)
let state = LynxMonitor.diagnostics()
let events = diagnosticProvider.snapshot()
~~~

iOS Provider 必须由宿主持有，才能在本地验收时读取 snapshot。redactText 可以由宿主提供业务敏感文本脱敏规则；不要把凭据放到事件或公共配置。

HarmonyOS：

~~~ts
const provider = new LocalDiagnosticProvider();
const monitor = LynxMonitor.shared();
const result = await LynxMonitor.install(
  { enabled: true, provider, performanceSampleRate: 1 },
  {
    platform: 'harmony',
    hostAppId: 'your-app-id',
    hostBuild: '42',
    runtimeVersion: '4.1.0',
    processSessionId: monitor.sessionId
  }
);
const events = provider.snapshot();
~~~

HarmonyOS 当前没有被官方资料证明的实例内存、CPU、长任务和三端统一流畅度 API。LocalDiagnosticProvider 会把这些能力标为 unsupported，不用 App 总内存或 Pipeline 耗时替代。

## 事件和大盘可以得到什么

每条事件都带有 processSessionId、eventId、platform、runtimeVersion、hostBuild、containerKind、viewId、loadId、visibility、质量状态和采样所有者。Bundle 字段区分 ota、embedded、direct_https、direct_asset，并保留 verified、computed、unavailable 身份状态。

当前可用于大盘的 Lynx PerformanceEntry 数据包括：

- LoadBundle / ReloadBundle 的 lynxFcp、prepare-to-fcp、open-to-fcp（有对应宿主时间戳时）。
- parse、background load、MTS render、style resolve、layout、UI operation、pipeline 阶段时长。
- LazyBundle 的已提供阶段字段。
- resource 回调的类型和错误码；4.1 回调没有可靠 duration/URL 时字段保持 null，并记录 missingFields。

JS 错误事件区分 background、main_thread 和 unknown，保留错误码、子码、级别、截断后的 message/rawStack、结构化帧和 loading/running 阶段。首屏后的 JS 错误不会触发首屏失败回滚；首屏前的错误仍交给原有错误页和 OTA 恢复流程。

暂不作为 Lynx 统一线上指标承诺的内容：

- 三端统一掉帧率、卡顿率和长任务率。
- HarmonyOS 等价的实例内存快照。
- 未经宿主或厂商证明的 Promise rejection 全量覆盖。
- 用一次 onSetup 或日志输出推导 FCP 数值。

## 构建归档和源码还原

Playground 的 Rspeedy 4.1 默认插件在 Debug Metadata 清理前生成归档。构建插件只把调试材料放到 dist 外的：

~~~text
playground/.artifacts/lynx-monitor/<buildId>/
  manifest.json
  entries/<entryId>/bundle.lynx.bundle
  entries/<entryId>/debug-metadata.json
~~~

生产 CI 构建使用：

~~~bash
cd playground
CI=1 pnpm build
~~~

官方 Rspeedy 为了避免普通本地 production 输出调试材料，在没有 CI/DEBUG 标识时会跳过 Debug Metadata 生成；这种本地构建会得到空归档并打印警告。要做 G1 归档验收，请使用 CI=1 或 DEBUG=lynx。

校验归档：

~~~bash
node scripts/lynx-monitor-artifacts/cli.mjs \
  check --manifest playground/.artifacts/lynx-monitor/<buildId>/manifest.json
~~~

还原错误：

~~~bash
node scripts/lynx-monitor-artifacts/cli.mjs \
  resolve \
  --event /tmp/lynx-monitor-event.json \
  --manifest playground/.artifacts/lynx-monitor/<buildId>/manifest.json \
  --output /tmp/lynx-monitor-result.json
~~~

后台文本堆栈使用 Source Map v3。主线程堆栈的数字位置按 Lynx Debug Info Remapping 的约定访问 line_col[pc_index - 1]，再使用同一 artifact 的 source-map；function_id 不会直接当作源码行号。找不到唯一 Bundle SHA、debug key、source map 或 bytecode debug info 时返回 unresolved reason，原始事件不会被覆盖。

当前没有 publish Provider。执行 publish 会返回 NOT_CONFIGURED，明确表示归档尚未进入任何云端平台。

## G1 三端最终验收（2026-09-15）

本次 G1 按动态工作流完成三端静态、构建、模拟器、Provider snapshot 和 crash marker 验收；以下结果取最终修复后的证据，不把早期冒烟记录重复算作最终通过。

### Android

- `LynxScreens_API35` / API 35 / `emulator-5554`。
- `:lynx-shell:testDebugUnitTest :app:assembleDebug --offline --no-daemon --console=plain` 成功。监控契约测试 `14/14`，整套 102 用例 0 failures、0 errors、3 个既有外部 HTTP 用例 skipped。
- APP 内 Debug 监控页在首个 LynxView 前安装 `local_diagnostic` Provider。最终修复后重新安装 APK，Page 和 Native Tab 运行并导出 25 条快照，`monitorState=ready`、队列 `0/0`、丢弃 `0`；此前更完整的 Page/资源页/Tab reload 流程导出 45 条，均保留在证据目录。
- 修复创建前 visible 误报，以及 `home.lynx.bundle` 单独解析 App ID 歧义。Page 事件顺序现在为 `created → visible → loaded_unconfirmed → first_content`。
- Page OTA 快照包含 release、sequence 和 SHA；Tab/reload 使用不同 view/load 身份。

### iOS

- iPhone 18 Pro Max Simulator / iOS 27.0 / UDID `2E98C9AA-9D32-4EEC-9A2E-E83BD90EDD6C`。
- `xcodebuild` 使用临时 `IPHONEOS_DEPLOYMENT_TARGET=15.0` 和 `-Wno-error=unused-result` 适配本机 Xcode 27/Pods，最终构建 `BUILD SUCCEEDED`；静态门禁 `113 PASS / 0 WARN / 0 FAIL`。
- `--lynx-monitor-diagnostic` 启动后，Page/Native Tab 日志显示 `ios.local_diagnostic` `ready`，快照数量由 4 增至 9，包含 performance、lifecycle、load 和 diagnostic。
- 修复 Provider 初始化失败/10 秒超时的清队列、dispose-once、迟到 completion 门禁；补普通后台 `file:line:column` 解析，主线程不确定位置仍保留 unknown。

### HarmonyOS

- Pura 90 Emulator / API 24 / HDC `127.0.0.1:5557`。
- `python3 harmony/scripts/check_harmony_shell.py --quiet`：`95 pass / 0 warn / 0 fail`。
- `hvigorw assembleApp --no-daemon` 最终 `BUILD SUCCESSFUL`；构建后 `harmony/lynx_shell_kit/BuildProfile.ets` 已恢复原始 debug/true。
- Want 显式带 `lynx_monitor_local=1` 安装 `harmony.local_diagnostic`；清空 HILOG 后 Page → Native Tabs → Settings/Home，快照从 0 增至 22，包含 `view.load=10`、`view.lifecycle=8`、`lynx.performance=4`。快照摘要附带 view/load 前缀、container、bundle、release、sequence 和 SHA 前缀。
- 修复 Harmony UUID 格式、失败状态继续采集、JS 错误脱敏/debugmetadata 帧定位、load 终态竞态、releaseSequence 丢失和 direct asset Bundle 名称缺失。G1 仍以事件循环串行消费者承载本地 Provider；未来慢厂商 SDK 必须在 Provider 内部自行隔离。

### 真实设备回调边界

- 三端均未在现有官方/内置 Bundle 稳定观察到 `lynx.resource` 或 `lynx.js_error`。Android 有 14 个监控契约用例覆盖资源/JS 事件、大 JSON 和脱敏；iOS/HarmonyOS 代码、类型和静态门禁覆盖接线与字段约束。
- 这两类事件需要后续专用测试 Bundle 才能成为三端运行态 PASS；当前不伪造“已收到”。

### 证据和 G2 边界

- 完整测试报告：[docs/lynx-view-monitoring-v1/g1-acceptance-report-2026-09-15.md](g1-acceptance-report-2026-09-15.md)。
- 命令和时间线：[docs/lynx-view-monitoring-v1/g1-execution-log-2026-09-15.md](g1-execution-log-2026-09-15.md)。
- 运行证据：[docs/lynx-view-monitoring-v1/g1-evidence/](g1-evidence/)。
- 当前没有第三方 SDK、网络上报、Token、云端大盘或线上 source map 服务；这些是后续 G2。

仍待专项验收：真实 JS Error/Resource Bundle、Provider 初始化超时/压力路径的设备级注入、真机/签名包/低磁盘/强杀恢复和厂商后台/source map 线上闭环。
