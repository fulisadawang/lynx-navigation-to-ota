# 运行时契约 v1.0

本文是跨端语义契约。TypeScript 仅用于表达统一数据形状；当前 Android、iOS、HarmonyOS 的平台实现位于各自 monitoring 目录，不要求原生事件经过 JS Bridge。

## 1. 标识与生命周期

| 标识 | 生成/来源 | 有效期 |
|---|---|---|
| `processSessionId` | 监控启用时生成随机 UUID | 当前进程，不写永久设备标识 |
| `viewId` | 为一次原生 LynxView 创建尝试生成 UUID | 实例销毁后不复用；创建失败可记录为未实例化的尝试 |
| `loadId` | 每次 initial/retry/reload 生成 UUID | 该次 load；回滚加载必须新建 |
| `eventId` | 记录事件时生成 UUID | 同一事件交付重试保持不变 |
| `nativeInstanceId` | SDK 提供时保留 | 平台原生实例号，仅用于诊断与关联，不单独充当全局 ID |

普通 Tab 切换只改变 visibility，不新建 viewId/loadId。真正重建 LynxView 产生新 viewId；同实例再次加载产生新 loadId。预创建页面标记 hidden，不能把预加载 FCP 等同于用户点击后等待时间。

绑定顺序：reserve viewId → 原生 prepare/load 开始分配 loadId → 本次字节身份解析 → 创建/绑定实际 LynxView → 注册监听 → load/render。实际容器顺序不同时，身份在 resolve 前明确 unavailable，不能倒填历史事件冒充当时已知。

生命周期事件可与性能事件乱序到达。`destroyed` 是实例生命周期事实，不是“所有 SDK 性能回调已经交齐”。已经入队的事件必须用冻结上下文完成分发，不持有 Activity/UIViewController/ArkUI Page。

## 2. BundleIdentity

```ts
type Sha256 = string; // 64 位小写 hex，边界规范化；不是任意版本字符串
type BundleSource = 'ota' | 'embedded' | 'direct_https' | 'direct_asset';

interface BundleIdentity {
  source: BundleSource;
  lynxAppId: string | null;
  bundleName: string | null;
  releaseId: string | null;
  releaseSequence: string | null; // 非负十进制字符串，不经 Number/Double
  sha256: Sha256 | null;
  identityStatus: 'verified' | 'computed' | 'unavailable';
  missingReason: string | null;
  buildId: string | null; // 仅已证实与实际字节对应时提供
}
```

- verified：哈希来自本次实际字节的已有成功校验；computed：直接对本次字节计算，未有预期清单可比对；两者都能标识内容，但可信发布身份不同。
- unavailable：尚未读到或无法取得内容；sha256 必须为 null，missingReason 必填。
- source/逻辑名称等可以先知道，版本字段缺失可以为空；`package.json.version`、宿主版本、URL 参数不能冒充 Bundle 发布版本。
- 身份在交付 render 的时刻冻结，后续 OTA current 更新、全局语言更新、Tab 变化不能改写它。
- 原生类型必须是只读值对象；不能把可变 Map 的引用共享给 Provider。
- SHA 工作放已有校验或后台读取过程；禁止为每条指标重新读文件、计算哈希。

## 3. 统一事件外层

```ts
interface EventEnvelope {
  schemaVersion: '1.0';
  eventId: string;
  processSessionId: string;
  observedAtMs: number; // 接收时的 Unix ms，不能冒充 SDK 发生时间
  platform: 'android' | 'ios' | 'harmony';
  runtimeVersion: string;
  hostBuild: string;
  viewId: string | null;
  nativeInstanceId: string | null;
  containerKind: 'page' | 'tab' | 'embedded' | 'unknown';
  loadId: string | null;
  loadKind: 'initial' | 'retry' | 'reload' | null;
  bundle: BundleIdentity | null;
  visibility: 'visible' | 'hidden' | 'background' | 'unknown';
  quality: {
    association: 'exact_load' | 'exact_view' | 'unassigned';
    late: boolean;
    missingFields: string[];
    invalidFields: string[];
    truncatedFields: string[];
  };
  sampling: {
    owner: 'core' | 'provider' | 'none';
    rate: number | null; // provider 未公开实际策略时为 null
  };
}

type EventType = 'view.lifecycle' | 'view.load' | 'lynx.performance'
  | 'lynx.js_error' | 'lynx.resource' | 'monitor.diagnostic';

type MonitorEvent = EventEnvelope & (
  | {eventType: 'view.lifecycle'; payload: LifecyclePayload}
  | {eventType: 'view.load'; payload: LoadPayload}
  | {eventType: 'lynx.performance'; payload: PerformancePayload}
  | {eventType: 'lynx.js_error'; payload: JsErrorPayload}
  | {eventType: 'lynx.resource'; payload: ResourcePayload}
  | {eventType: 'monitor.diagnostic'; payload: DiagnosticPayload}
);
```

eventType 与 payload 必须按下表对应，不能把任意字典当合法事件。新增事件类型需更新版本及 Provider capabilities。JSON 中禁用 NaN/Infinity；所有时长单位固定 ms。

LifecyclePayload、LoadPayload、PerformancePayload、ResourcePayload、DiagnosticPayload 分别按下表完整定义；JsErrorPayload 见第4节。Schema是这些结构的机器可读约束，原生实现也须按事件种类穷举处理。

### 3.1 Payload 定义

| eventType | 必需 payload | 说明 |
|---|---|---|
| `view.lifecycle` | `{state: created / visible / hidden / background / destroyed / create_failed, durationMs?: number|null}` | created 仅实际创建成功；create_failed 可没有 SDK instanceId；created.durationMs为原生单调时钟测得的创建耗时 |
| `view.load` | `{phase: started / resolved / loaded_unconfirmed / first_content / failed / cancelled / incomplete, reasonCode?: string, durationMs?: number|null}` | SDK load-success 不等于首次内容；failed 只由真实失败事实产生；resolved.durationMs用于bundle_prepare_ms |
| `lynx.performance` | `{entryType, entryName, identifier: string|null, metrics: MetricValue[], timing: Record<string,number>}` | 只提取 SDK 支持的原始时间字段；字段清单按 R0 定稿，不上传任意原始对象 |
| `lynx.js_error` | 见第 4 节 | 同时包括首屏前和运行期；与加载失败处理解耦 |
| `lynx.resource` | `{resourceType, outcome: success / failed, durationMs: number|null, errorCode: string|null, resourceKey: string|null}` | duration 无可靠来源为 null；resourceKey 不能含签名参数 |
| `monitor.diagnostic` | `{code, count: number, detail: string|null}` | 适配器拒绝、截断、丢弃、关联缺失；不得递归触发自身上报 |

```ts
interface MetricValue {
  name: string; // README 指标白名单
  value: number; // finite 且 >= 0；合法 0 与缺失区分
  unit: 'ms';
  origin: 'sdk_duration' | 'sdk_timestamp_difference';
  sourceFields: string[];
}
```

SDK native extras 不同端字段名不强行统一。公共指标字段相同但时间起点不同必须拒绝映射，不能只因都叫 FCP 就合并。

`bundle_prepare_ms`从view.load的resolved.durationMs派生，不额外伪造一条SDK PerformanceEntry；同一测量只提交一个事实事件。若消费已有ActualFMP标记，v1保留其对应SDK时间字段和identifier；新增归一化ActualFMP指标名称需另作minor版本扩展。

内存和卡顿探测结果在 R0 单独记录，不挤进上述 MetricValue。若能力通过，新增独立的诊断快照契约，明确 bytes、区间和归属；不把 App 级数值伪装成 View 指标。

### 3.2 载入关联规则

1. 能由绑定闭包明确识别 View 的，归属到原 viewId；实例重建的旧回调不能进入新 View。
2. 多次同 View load 时，只能使用已认证的逐事件 load/操作标识关联。当前官方 LoadBundle/ReloadBundle 的 identifier 为空，不可用作 loadId；接收时间窗口、URL 或更换 listener 均不构成可靠证据。
3. `onPageStarted` 的 URL / reload origin 不是唯一 loadId；换 listener 也不能证明回调属于新 load。
4. 同 View 的旧新 load 重叠、SDK 事件无唯一关联信息：保留 viewId，loadId 与 bundle 清空，association=exact_view，并记录 ambiguous_load；不能按当前 load 猜测，也不参与版本分位数。
5. 无法归属到某个 View 的共享 runtime 错误：association=unassigned，viewId/loadId/bundle 均为空，保留帧里的调试 key；不把错误分摊或复制给所有 View。
6. 已归属的 late 事件使用原身份；close gate 在取消任务/摘除 listener/销毁 View 前原子关闭，close 幂等。关闭前已入队的不可变事件允许排出；关闭后新到的回调拒绝并计数，不延长活体 UI/OTA lease。
7. 对首屏与 reload 的 FCP，按 loadId + 指标名称选一个主样本；同一 SDK 原始事件已转发过不得再次经另一个 client 入口转发。真实连续两次同样错误仍是两条 occurrence，不能按 message 时间窗随意去重。

`exact_view` 时 loadKind 也清空。发现无认证逐事件标识的同 View reload 后，未知归属事件持续走该通道，直到物理实例重建或得到经过验收的关联机制；不能仅在 reload 瞬间标记一次，随后又默认归属最新 load。

### 3.3 加载统计状态

每个 load 开始一条 started；得到实际字节后 resolved；仅 load-success 时为 loaded_unconfirmed；真实首次内容信号时 first_content，至此该次加载成功。首屏后的 JS 错误另发 js_error，不把既有加载成功改为失败。

首屏前发生致命加载/渲染错误为 failed；用户离开导致取消为 cancelled；无法确认结束原因为 incomplete。三者不能混合计算渲染失败率。首次内容的生命周期与 performance 回调应幂等确认同一个 load。

## 4. JS 错误与定位帧

```ts
interface JsErrorPayload {
  errorCode: string | null;
  subCode: string | null;
  level: 'fatal' | 'error' | 'warning' | 'unknown';
  realm: 'background' | 'main_thread' | 'unknown';
  message: string;
  rawStack: string | null; // 经约定字段处理后保留，不能只取 message
  frames: ErrorFrame[];
  handled: 'unhandled' | 'reported' | 'unknown';
  phase: 'loading' | 'running' | 'unknown';
}

type ErrorFrame = {
  file: string | null;
  functionName: string | null;
  runtimeRelease: string | null; // 原样保留 debugmetadata:<key>
  debugKey: string | null; // 只去掉已知前缀；不能由 OTA SHA 假造
} & (
  | {positionKind: 'line_column'; line: number; column: number}
  | {positionKind: 'function_pc'; functionId: number; pc: number}
  | {positionKind: 'unknown'}
);
```

- 定位含义由引擎/脚本实际格式决定；文件名不是充分判据。当前官方主线程 bytecode 路径须两段反解。后台 bytecode 变体也不能强制当文本行列。
- 保留 runtime 原始行列；传给具体 v3 Source Map 库时按输入格式校验列基准，不盲目统一减一；使用已知 throw 行作为金标准验证。
- 自定义 UI 错误提示、原生堆栈、JS 异常分别分类；不将每个 `onReceivedError` 都标为 JS，也不制造原生异常对象当作 JS 崩溃投递。
- 首屏后的 timer、事件、Promise、main-thread handler 等属于必须测试的采集场景；回调没有覆盖的类型必须披露。被捕获且未报告的异常不在自动观测承诺内。
- 若决定补公共 `lynx.reportError` 接入，作为后续独立任务；v1 不向所有业务 Bundle 注入 ErrorBoundary/global catch 以宣称全覆盖。

## 5. 可替换运行时 Provider

### 5.1 公开语义

```ts
interface MonitorConfig {
  enabled: boolean;
  provider: RuntimeProvider | null;
  performanceSampleRate: number; // 默认 1；同一 View 整组采样
}

interface RuntimeProvider {
  readonly id: string;
  readonly capabilities: ProviderCapabilities;
  initialize(context: HostContext): Promise<InitResult>;
  record(event: Readonly<MonitorEvent>): HandoffResult;
  flush?(timeoutMs: number): Promise<FlushResult>;
  dispose(): void;
}

interface HostContext {
  platform: 'android' | 'ios' | 'harmony';
  hostAppId: string;
  hostBuild: string;
  runtimeVersion: string;
  processSessionId: string;
}

interface ProviderCapabilities {
  platform: 'android' | 'ios' | 'harmony';
  supportedEvents: EventType[];
  perEventBundleContext: boolean;
  rawJsFrames: boolean;
  sdkOwnsRetry: boolean;
  flushSupported: boolean;
  samplingOwner: 'core' | 'provider';
}
type InitResult = {state: 'ready'} | {state: 'failed'; reason: string};
type HandoffResult = {state: 'accepted_by_sdk' | 'recorded_locally'}
  | {state: 'rejected'; reason: 'unsupported' | 'not_ready' | 'invalid_event' | 'provider_error'};
type FlushResult = {state: 'completed_sdk_flush' | 'unsupported' | 'timed_out' | 'failed'};
```

这不是 HTTP ACK 协议。accepted_by_sdk 只表示交给 SDK，不代表云端已收到；completed_sdk_flush 不等于成功入库。线上到达状态必须由厂商平台查询或其明确回执验证。

HostContext 只包含 platform、runtimeVersion、宿主 app 标识/构建号与进程会话；SDK 凭据/初始化参数由具体 Provider 自身管理，不属于 MonitorEvent。已由宿主初始化的 SDK 可以被适配器采用，不重复初始化。

### 5.2 初始化和关闭

- 公开入口统一表达 `LynxMonitor.install(config)`；实际 Kotlin/Swift/ArkTS 签名在 R1按该语义实现。必须在首个需要监控的 View 创建前完成。
- enabled=false：不安装 SDK 监听；enabled=true 而无 Provider：返回 not_configured，不能悄悄 Noop 后声称采集成功。
- 初始化未完成不延迟页面加载；事件仅进入有界内存队列。初始化成功后顺序排出；失败时清理队列并记录 discarded_count。
- initialize 首版等待预算 10 秒，只作用于监控状态；超时标记 initialization_timeout，清理待发事件。迟到 ready 结果不得复活已关闭/失败实例；是否恢复需要显式重新启动监控进程生命周期，不做隐式重试。
- Provider 固定在进程生命周期；重复相同 install 幂等，不同 Provider 的二次 install 拒绝为 already_initialized。
- 单 View 销毁只清理 View 绑定，不 dispose 全局 Provider；dispose 用于整体监控关闭，不能关闭由其他模块共同使用的第三方 SDK。

### 5.3 线程和背压

- 原生 UI 操作继续在各端 UI 线程；哈希、序列化、网络不在 UI 线程执行。
- 回调只复制白名单标量/结构并入队；Provider.record 在监控自己的串行执行器调用，不在 Lynx render/report 回调里直接调用阻塞 SDK。
- `record` 必须快速返回交付结果；SDK 若要求主线程，Provider 只调度该 SDK 调用，不能搬整条加工/上传链到主线程。
- 首版公共队列最多 128 条且总计 512 KiB；单事件最多 32 KiB；JS stack 16 KiB、最多 64 帧、message 4 KiB。达到限制必须标记截断/丢弃计数。
- 大小限制按 UTF-8 字节计；Schema 的 maxLength 仅检查字符数，运行时必须额外检查编码字节数。上述预算是待实测设计值，不是已经验证的开销结果。
- 队列满时先丢最旧的 performance/resource；若全是 lifecycle/error，则丢最旧事件并增加对应类型 dropped_count。队列内与排出的每条事件保持独立身份，不能无限增长。
- 不在公共层建持久化 outbox 或重试；accepted 后可靠发送由 SDK 负责。没有可靠发送的 Provider 必须披露风险，不允许核心偷偷再发一份。
- Provider 抛出异常转为 provider_error，本次事件不重试，不能影响页面；异常对象/日志不反向进入同一 Provider 造成递归。持续故障由诊断统计反映，不自动切换厂商。

### 5.4 采样与统计

- G1 全量采集（rate=1），便于逐事件对账。
- 接入厂商后只有一个采样所有者。core 模式按 viewId 做确定性性能采样；provider 模式 core 不再二次采样，未知实际率记 null。
- performanceSampleRate 接受 0～1；0 表示不生成性能样本，已生成事件的 sampling.rate 不得为0。Provider声明自己采样时，公共sampleRate必须为1，否则配置返回sampling_conflict。
- lifecycle/load 基础记录不随机采样；性能样本附采样率，JS 异常默认不参与性能采样。这些记录仍可能因队列上限/SDK限制丢失，须披露 dropped_count，不承诺无损全量。
- 第三方 SDK 若对异常另有采样/限速，需在集成说明中明确；不得声称 100% 到达。
- 平台分位数只统计有效且唯一归属的样本，并展示样本量。无法确定覆盖分母或 SDK 采样率时显示 unavailable，不凭观察到的事件推算全量成功率。

## 6. 字段处理

- 不采集 initData、完整 GlobalProps、业务表单、用户身份、请求 body/header、token/cookie。
- Bundle 来源身份不依赖原始 URL；必须记录 URL 时只保留已约定的无 query/fragment 路径或受控散列。JS frame 的生成文件名和 release key必须保留用于还原。
- 错误 message/rawStack 可能混有业务数据，在适配器前执行配置明确的脱敏/截断；不能删掉全部堆栈后还声称支持反解。
- 原始 DebugMetadata 可能包含源码，只进入构建机的私有归档与选定平台的受控上传，不随 App/Bundle 发布。

## 7. Provider 合格条件

必须证明性能与错误都能保留 viewId/loadId、Bundle hash、脚本 debug key；第三方仅能使用进程全局 Bundle release 的，不合格。允许映射成厂商自定义事件，但必须能查到原始记录并区分发生次数与影响实例数。

性能成功、错误成功、产物上传成功和源码还原成功是四项独立验收。能力声明必须有测试证据；`supportsAll=true` 等不经核验的总开关禁止使用。
