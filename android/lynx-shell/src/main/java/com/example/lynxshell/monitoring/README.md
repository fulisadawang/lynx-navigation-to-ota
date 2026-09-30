# Android LynxView 监控 G1

适用 Runtime：当前实际解析的 Lynx 4.1.0 AAR；进程版本从 `BuildConfig.LYNX_RUNTIME_VERSION` 获取。
本模块处理系统观测和通用业务事件的有界内存分发；第三方平台、HTTP 和持久队列由后续 Provider 接入负责。

## 宿主接入

在首个需要监控的 View 创建前，由 Application 保存 Provider 并调用：

```kotlin
val diagnosticProvider = DiagnosticProvider()
val result = LynxMonitor.install(
    application,
    MonitorConfig(
        provider = diagnosticProvider,
        performanceSampleRate = 1.0,
        textPolicy = MonitorTextPolicy(redactedLiterals = listOf()),
    ),
)
```

`result.state=initializing` 表示初始化已启动；状态、排队量和丢弃原因通过
`LynxMonitor.diagnostics()` 查询。未配置 Provider 返回 `not_configured`，不安装监听。
同配置重复安装幂等；不同 Provider、采样配置或字段策略返回 `already_initialized`。
监控关闭或初始化失败后不可在当前进程隐式切换 Provider。

`diagnosticProvider.snapshot()` 返回有界不可变事件快照，`event.toJson()` 用于后台导出。
`recorded_locally` 只表示本地内存记录；本地 Provider 不声明 SDK flush 或可靠发送能力。
事件缓存满时旧事件会被淘汰，`discardedCount()` 可以查询本地缓存淘汰总数。

## 业务事件入口

页面在 Background Thread Scripting 中调用现有 `NativeModules.LynxShellModule`：

```ts
reportBusinessEvent(
  group: string,
  name: string,
  attributesJSON: string,
  callback: (result: NativeBusinessEventResult) => void,
): void
```

分组、名称和属性字段由业务方自由定义，支持中文、英文及业务所需字符；分组与名称不能为空或全空白，保留原文。
属性必须是扁平 JSON object，只接受 string、finite number、boolean；空属性传 `{}`。
三个原始字符串合计先执行 32 KiB 输入检查，属性字符串入队前经过 `MonitorTextPolicy.sanitize` 与宿主 `redactedLiterals` 清理。
完整不可变事件再按 JSON 转义后的字节执行 32 KiB 预算，超限拒绝，不截断业务字段。

入口从 Module 的 `LynxContext.getLynxView()` 查本物理 View 的活动 Scope，在 Scope 与 runtime 锁内检查关门状态、Provider 能力和队列容量。
成功仅在真实 append 后返回 `{ code: 0, message, data: { stage: 'queued', eventId, monitorState } }`，状态为 `initializing` 或 `ready`。
失败返回非零 code 与 `{ stage: 'rejected', reasonCode }`；失败码与原因见根目录 `BRIDGE_CONTRACT.md`。
Provider 后续拒绝、异常或事件淘汰仅更新监控诊断，不回填已完成回调；queued 不代表厂商 SDK 或云端收到。
业务事件沿现有串行 worker 调用 `Provider.record(event)`，不在 Bridge 内调用 SDK 或网络。

所有事件统一为 Schema 1.0，并有必填外层 `group`：生命周期/加载为 `page`，性能为 `performance`，JS 错误为 `error`，资源为 `resource`，诊断为 `diagnostic`。
业务 `eventType=business.event`，group 使用页面传入值，payload 仅包含 `name/attributes`；group 不改变采样、能力判定或队列优先级。
Provider 可读取 `event.group` 与 `BusinessPayload` 的类型明确、不可变属性；本地 Diagnostic Provider 已声明并实际记录业务类型。
业务能力不属于 Provider 安装的强制能力；未声明 `EventType.BUSINESS` 时入口返回 `event_unsupported`。

## 采集与身份

- Page 和 Native Tab 在 prepare 前 reserve 独立的 viewId/loadId；普通显隐切换不会创建新身份。
- Factory 在首次 render 前安装 V1 错误/首屏与 V2 性能/资源监听；销毁、刷新、失败和快照释放时先关门，再取消请求和销毁 View。
- OTA 使用本次 `PreparedActivityBundle` 的 release/hash，内置清单使用 `embedded_baseline` 来源。
- 直连及未登记资源在 Provider IO 线程复用实际字节计算一次 SHA，状态为 computed；历史 started 事件仍保持当时的 unavailable 身份。
- Application 的 started/stopped 回调提供进程前后台状态，Page/Tab 各自记录 hidden/visible。
- SDK 回调无可靠 load key 的同 View reload 保持 exact_view，清空 load/bundle；常规 Page/Tab 刷新本身会重建物理 View。

性能接收 LoadBundle / ReloadBundle / Pipeline / LazyBundle 白名单字段；缺失、负值、非有限值、倒序时间不会变成 0。
FCP 只采用 LoadBundle/ReloadBundle 主样本，不接旧 MetricFcp 重复通道；资源回调没有 duration/URL 字段，相关值明确为 null。
首屏后的 JS 错误保持独立 occurrence，不将已成功 load 改成失败。

## 字段处理与诊断

默认移除 HTTP URL 的 query/fragment、常见凭据字段和值；宿主可通过 `redactedLiterals` 指定额外的业务敏感文本。
SDK 不提供 callStack getter；回调只通过 `getMsg()` 冻结字符串和必要标量，JSON 解析、脱敏及帧处理都在监控串行线程执行。
完整解码快照计入 512 KiB 公共工作预算，超过队列硬上限直接拒绝并计数，不截断 JSON 后冒充完整可解析输入；最终投影事件仍受 32 KiB 上限约束。
内部解码快照与事件共用有界队列，最终只交付已知 error_stack/release 和结构化 getter 字段，不交付完整 SDK 错误 JSON、用户上下文或原始 URL。
错误消息限制 4 KiB，原始 stack 16 KiB，帧最多 64 个且合计预算 6 KiB。长度按 UTF-8 计算，截断标记写入 quality。

显式 function_id/pc 解析为 function_pc。普通 `:n:m` 必须由 `MonitorConfig.scriptPositionFormats` 按脚本 debugKey 登记 `LINE_COLUMN` 或 `FUNCTION_PC`，数据来源应为本次构建清单。
没有登记时两个 realm 都保持 unknown，rawStack 和调试 key 保留；不能仅按 main-thread/background 或文件名猜脚本格式。
已登记文本格式保留原始列值，已登记 bytecode 格式保留函数 ID 与 PC；实际准确性仍需构建产物与错误金标准验收。

公共队列上限 128 条 / 512 KiB，单事件 32 KiB。业务入队只淘汰最旧 performance/resource，先预计算完整容量；不足时拒绝且不删除旧事件。
系统入队按 performance/resource、business、原有兜底顺序淘汰，每次淘汰按事件类型计数。Provider 初始化预算 10 秒。
Provider.record 仅在独立串行线程执行，抛异常转换为 provider_error，不重试、不回调页面、不递归上报。
初始化失败与显式关闭共享一次性 dispose；Provider 应在 dispose 中取消自己尚未完成的初始化工作，不得因迟到回调复活 SDK。
`LynxMonitor.diagnostics().counters` 区分队列丢弃、投递拒绝、性能采样、无关错误和关门后的回调。

## 验证边界

纯 JVM 契约测试位于 `src/test/kotlin/com/example/lynxshell/monitoring/MonitoringContractTest.kt`。
性能回调仍进行固定白名单数值复制、差值校验和有界计数；没有 JSON/网络/文件处理，设备回调开销尚未实测。
SDK 类型/字段使用当前本机 4.1 AAR `javap` 和官方同 tag 源码核对。
测试和库编译不证明真机 timer/Promise/main-thread 异常覆盖，也不证明厂商平台收取或源码还原。
业务接线位于 Library；实际 Page/Tab 采集验收需宿主按上述入口启用本地 Provider。
本轮业务事件修改仅完成静态源码与 diff 核对，未执行测试、类型检查、Lint、编译、构建或设备验证。
