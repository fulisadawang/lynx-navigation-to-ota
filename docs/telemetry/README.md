# Lynx Router Telemetry Phase 0 契约

本目录是 Router + OTA 生产监控的共享契约层。它只描述字段、状态和 fixture，**不负责网络上传、磁盘
队列或 OTA 下载**。三端实现（Android / iOS / HarmonyOS）必须先把 Native 生成的事件归一化到这里，
再交给唯一的 Delivery Owner。

## 版本与兼容边界

| 契约 | 当前版本 | 作用 |
| --- | --- | --- |
| Event Wire Schema | `3.0.0` | 事件 Envelope、身份、Bundle Snapshot、生命周期、采样和脱敏字段 |
| Remote Config Schema | `1.0.0` | 开关、稳定采样、预算、版本和 fail-open 规则 |
| Delivery/Privacy | `1.0.0`（与 Event 独立） | Batch ACK 与 opt-out deletion tombstone |

`schemaVersion` 是数据协议版本，不等于 Router/SDK 版本，也不等于 HTTP Endpoint 版本。删除字段、改变
字段含义或改变枚举语义必须升级 Wire Schema major；向后兼容的新增字段进入 minor 适配器后再落盘。

## 事件 Envelope

规范文件：[`event-envelope.schema.json`](../../schemas/telemetry/event-envelope.schema.json)。

必填字段保证任何平台都能做低基数聚合：

- Native 生成：`schemaVersion`、`eventId`、`occurredAtUnixMs`、`monotonicOffsetMs`、`sequenceNo`。
- `category` 使用低基数枚举（`router` / `navigation` / `page` / `app` / `transition` / `performance` /
  `resource` / `runtime` / `error` / `bridge` / `exposure` / `business` / `ota` / `diagnostic` /
  `telemetry`）；`navigation` 和 `transition` 是 Router 受理与转场的独立维度，不代表首屏成功。
- 运行身份：`runtimeKind`、`runtimeInstanceId`、可选 `runtimeGeneration`。
- 页面身份：`navigationId`、`navigationSessionId`、`pageViewId`、`entryId`、`renderAttemptId`、
  `activationId`、`transactionId`；无法建立的身份使用 `null`，禁止用空字符串伪造。
- 版本与宿主：`hostMode`（`activity` / `view_controller` / `arkui_page`）、`platform`、`hostApp`、
  `appVersion`、`buildNumber`、`lynxSdkVersion`、`engineVersion`。
- 采样与交付：`sampleRate`、`samplingGroup`、`samplingRuleVersion`、`analysisEligible`、
  `deliveryOwner`。

### 身份不变量

`entryId` 是 Native 容器寻址键；`pageViewId` 是一次用户页面访问；`renderAttemptId` 是一次可以被
reload/回滚替换的渲染尝试；`activationId` 是页面可见、App 前台且 attempt 可用的一段连续活跃区间。
覆盖返回或前后台切换只新建 `activationId`，不重复制造 page view；回滚必须在同一 `pageViewId` 下新建
`renderAttemptId`。

### Attempted / Resolved Bundle Snapshot

页面容器在 `prepare()` **之前**冻结 `attemptedBundleSnapshot`，因此缺包、下载、大小或 SHA 校验失败也有
可归因的候选信息。只有安全交给 Lynx 的结果才能冻结 `resolvedBundleSnapshot`。

- `bundleSource`：`ota` / `direct_https` / `assets` / `local_file`。
- `bundleName` 和 `telemetryRouteKey` 是安全逻辑键；不接受 URL、query、fragment、userInfo。
- `releaseId`、`bundleSha256` 只在 resolved 后填入；直接 HTTPS 不虚构 OTA release 或 SHA。
- 本机绝对路径永远不在 Schema 中，不能写入事件、日志或磁盘队列。
- 回滚的 resolved snapshot 通过 `rollbackFromReleaseId` 关联坏版本和恢复版本。

### 生命周期与状态正交

`lifecycle.pageState`（`allocated` / `registered` / `visible` / `hidden` / `destroyed`）、
`lifecycle.appState`（`foreground` / `background`）和 `lifecycle.attemptState`
（`usable` / `unusable`）必须独立记录。只有三者计算出的 `activeEligible=true` 时，才能累计活跃停留和
有效曝光。页面被覆盖不等于 App 进入后台。

`navigationAdmission` 只表示请求是否 `requested`、`accepted` 或 `rejected`；
`transition` 的 `terminal` 只表示转场 `completed` / `degraded` / `cancelled` / `failed` /
`notApplicable`。accepted 不等于首屏成功，转场终态也不等于 Lynx 业务 ready。

### 曝光字段

`exposure` 使用 Native 生成的 `exposureSessionId`、`occurrence` 和 `observerGeneration`。
`lynx.exposure.qualified` 是曝光次数唯一分子；`lynx.exposure.ended` 只补充时长和结束原因。
covered/background/destroyed 后必须封口，恢复时 disconnect + recreate + re-observe，并等待真实回调，
不能由 `resumeExposure()` 人工合成一次曝光。

`lynx.page.activation_started/ended` 和 `lynx.exposure.resume_requested` 是低频 Native 状态事件：前者
只记录 `pageState=visible + appState=foreground + attemptState=usable` 的区间边界，后者只记录观察器
重建请求；它们都不是首屏、曝光分子或转场完成信号。

## Remote Config 1.0.0

规范文件：[`remote-config.schema.json`](../../schemas/telemetry/remote-config.schema.json)。

- `failOpen=true` 是硬契约：配置失联、过期或校验失败时，Router、页面加载和 OTA 继续工作；只关闭
  监控可选能力并回落到本地保守采样。
- `killSwitch.enabled` 是远程诊断开关；它不能阻断业务导航。
- `switches` 分离 page/performance/exposure/business/upload/diskQueue/diagnostics。首版
  `backgroundRuntime=false`，因为当前三端没有显式 standalone BackgroundRuntime 主链。
- `sampling` 所有值在 `[0,1]`；同一漏斗的 page/exposure/click 必须使用相同 `samplingGroup` 和
  `samplingRuleVersion`，并额外产生 `sampled_page_view` 分母。
- `budgets` 只能被远程配置缩小，不能超过 App 内置硬上限；`maxBatchBytes` 不得超过 64 KiB。
- `deliveryOwner` 只允许 `internal` 或 `external`，二者不能同时落盘和重试。
- `localOverrideContract` 记录接入约束：本地硬关闭由宿主拥有，远程配置只能关闭能力，不能打开本地已关闭
  的开关。真实本地开关存储在宿主配置，不从网络反序列化。

## Delivery 与隐私

规范文件：[`delivery-privacy.schema.json`](../../schemas/telemetry/delivery-privacy.schema.json)。

`batch_ack` 的 ACK 是 at-least-once 交付确认：服务端按 `hostApp + eventId` 幂等，客户端只删除
`acceptedEventIds` 或不可重试的 rejected 事件。

`deletion_tombstone` 是独立合规队列中的最小记录，只能包含
`deletionRequestId`、旧 `oldSubjectRef`、时间和尝试状态；不能携带页面、Bundle、URL、用户输入或事件
内容。opt-out 顺序为：停止采集 → 写 tombstone → 删除普通分析队列 → 轮换本地 pseudonym → 服务端
receipt/ACK → 清理旧 subject reference。

## Fixtures

共享样例位于 [`fixtures/telemetry`](../../fixtures/telemetry)：

| Fixture | 验证点 |
| --- | --- |
| `page-first-screen.json` | 正常 OTA 首屏、resolved snapshot、transition completed |
| `prepare-failure.json` | prepare 前冻结 attempted snapshot，失败不伪造 resolved |
| `rollback.json` | 同 pageView 的坏版本尝试与恢复版本 snapshot |
| `stale-callback.json` | 旧 generation 回调丢弃，不覆盖新 attempt |
| `exposure-recovery.json` | covered 返回后的 observer generation 与 occurrence |
| `sampled-page-view.json` | 曝光漏斗的同 cohort 分母 |
| `background-runtime-out-of-scope.json` | BackgroundRuntime 身份独立且首版不进入分析 |
| `remote-config.json` | fail-open、开关、采样、预算、Owner |
| `deletion-tombstone.json` | opt-out 独立最小 tombstone |
| `batch-ack.json` | accepted/rejected/可重试 ACK |

`invalid/` 中的样例故意违反版本、SHA、采样、隐私或枚举规则，确保 CI 不会只检查“文件能解析”。

## 本地校验

无需安装依赖，在仓库根目录执行：

```bash
python3 schemas/telemetry/validate_fixtures.py
```

脚本会读取三个 Schema，要求 `valid/*.json` 全部通过、`invalid/*.json` 全部被拒绝。它只实现本目录使用
的 JSON Schema 子集，不能替代服务端完整 JSON Schema 校验；服务端上线前仍需使用正式校验器和 PII/Secret
二次扫描。
