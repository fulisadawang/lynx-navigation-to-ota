# AGENTS.md — HarmonyOS `lynx_shell_kit`

> 本文件面向 AI 编程代理，对 `harmony/lynx_shell_kit/` 及其子目录生效。与仓库根规则冲突时遵守更高层级规则；本文件只补充 HarmonyOS HAR Module 的局部边界。

## 模块定位

`lynx_shell_kit` 是业务方接入 Router/OTA 的 HarmonyOS HAR Module，负责：

- Lynx 4.1 Runtime、Service、XElement 和模块初始化；
- ArkUI `LynxContainer`、Router、原生 Page Stack 与页面状态；
- `LynxShellModule`、Storage、消息和宿主能力 Bridge；
- LynxView 监控 Core、七类 Schema 1.0 事件与本地 Diagnostic Provider；
- Bundle Provider、embedded rawfile Registry；
- OTA Store v3、完整 Manifest、App ID 作用域 CAS、State、lease、回滚和诊断。

`harmony/lynx_shell/` 是 Entry Demo，只依赖 HAR，不属于本目录。不要把 Demo 页面、按钮或测试配置放进 HAR 公共实现。

`harmony/lynx_capacitor_kit/` 是独立原生能力 HAR，当前已显式加入根 build profile 和 Entry Demo。Shell不反向依赖Cap，由Entry通过中性HostNativeModules SPI注册并提供真实Ability/UIContext/Window和可见性；跨模块任务先读其AGENTS.md。不要把默认Demo接线误写为未装配，也不要让业务Shell隐式依赖Cap。

## 开工前必须读取

按任务相关性读取：

1. 根目录 `PROJECT_MAP.md`、`ARCHITECTURE.md`。
2. `harmony/README.md`、`harmony/ARCHITECTURE.md`。
3. 本目录 `oh-package.json5`、`build-profile.json5`、`hvigorfile.ts`。
4. 接入/路由：`MODULE_INTEGRATION.md`、`ROUTER_CONTRACT_V1.md`、`ROUTING.md`、`NAVIGATION_README.md`。
5. Bridge：`BRIDGE_CONTRACT.md`。
6. OTA：最新 Store v3 测试用例、Harmony HTML 报告和 `scripts/ota-store-v3/`。
7. 静态门禁：`harmony/scripts/check_harmony_shell.py`。
8. 跨到原生能力层时：`harmony/lynx_capacitor_kit/AGENTS.md` 和 `LynxCapacitorCatalog.ets`。

文档、代码和运行结果冲突时，以当前 ArkTS/ArkUI 源码、OHPM/Hvigor 配置和本轮授权范围内的验证为准；旧 HDC 证据不能替代当前非设备门禁。

## 目录与职责

```text
src/main/ets/
├── client/        LynxView 回调与每 View 监控 Binding
├── common/        请求、配置、GlobalProps 和公共类型
├── module/        LynxShellModule Bridge
├── monitoring/    事件模型、业务输入/回执、Context 索引与有界队列
├── ota/           API Client、Store v3、Runtime、embedded Registry
├── pages/         LynxContainer、LynxTabContainer
├── provider/      Bundle/Template Provider
├── routing/       LynxRouter、LynxNavigator、命令选项和逻辑页面栈
├── transition/    Native Navigation adapter、proxy、Canvas、Shared/Open/preset与预热token
└── runtime/       Lynx Runtime/Service/XElement 初始化
```

不要把 `harmony/lynx_shell/src/main/ets` 的 Entry Demo 实现复制进 HAR。需要演示时由 Demo 依赖公开 API。

## 不可破坏的架构约束

### 1. HAR 与依赖所有权

- 业务只依赖 `@lynx/lynx-shell-kit`；Lynx、Service、XElement 和 OTA 依赖由 HAR 管理。
- 不让 Demo 重复声明 HAR 已拥有的底层依赖。
- ArkTS 代码保持显式、可静态分析的类型；避免动态对象、隐式 any 和不受支持的 TS 语法。
- 不手改 `oh_modules/`、`.hvigor/`、build 输出或 OHPM lock 中的安装产物来替代源码修复。
- 未经明确授权不要升级 API level、Lynx/XElement 版本或依赖来源。

### 2. Router 与容器

- 默认承载是ShellNavigationHost中的Navigation/NavPathStack+NavDestination/LynxContainer，标题与业务导航继续Lynx自绘。公开API不泄露底层物理栈ID。
- Native proxy是唯一转场owner；真实onTransitionEnd才提交/取消，计时器只能超时拒绝不能假成功。缺Host返回1004，已初始化等待Area-ready有界；销毁结算未完成请求。
- animated、deduplicate及0..5000ms整数窗口由统一CommandOptions消费；实际push/replace/pop/clear均经过driver。私有复用替换不二次admit。
- Shared/Open/preset已形成源码闭环，不再固定返回legacy Router degraded。getTransitionState返回当前真实DTO；Native source/target几何在actual UIContext中将px转换vp，不相信JS上报坐标。
- heroSheet为透明全屏承载，canonical detents=[28,56,100]/初始56由Lynx管理，不添加Native barrier/detent/关闭手势；bottomSheet才消费Native高度档位与手势。
- 64MiB全局快照预算包括inflight/pending/临时mask和late释放；无法截图采用明确live fallback。复杂洞父gradient/image不可完整复原，不声称像素/FPS一致。
- covered/hidden不能提前销毁Context/lease；maintainState=false等Native成功后释放，返回onWillShow先加载，cancel恢复同代。解绑用exactContext，NativeTab不作导航结果receiver。
- prepareRoute真实预取，4条/32MiB/30秒一次token；OTA预热不TRIAL，真实消费claimlease。Source Context/session/snapshot/epoch失效不能交错字节。
- Window策略按actual top apply/restore，默认fullscreen=false不关闭宿主既有edge布局，保底部系统导航条。API13请求keyboardBehavior nothing/none明确拒绝，API14+才使用NONE。
- Direct Bundle 与 OTA Bundle 身份严格分离；禁止用 URL 猜 App ID 或把手机路径传入 Router。
- Page/普通open共用entry与结果语义；NativeTab共用Bundle/runtime/session来源，仅作宿主锚点，不加入Page结果entries，保留独立消息Context。
- Native Tabs 只是容器能力；HAR 不拥有业务 TabBar 设计或导航配置。

### 3. OTA Store v3

固定逻辑布局：

```text
<context.filesDir>/lynx-ota-store/apps/<lynxAppId>/
├── state.json
├── embedded.json
├── manifests/<manifestId>.json
├── objects/<sha前两位>/<sha>.lynx.bundle
└── transactions/<transactionId>/
```

- `candidateActivationEnabled` 默认关闭；开启后完整下载进入 PENDING，真实取包校验并持 lease 才进入 TRIAL，SDK 首屏与业务健康确认双信号后提交 current。旧 State JSON 兼容读取，候选也是 GC root；不把普通 onLoadSuccess 当作健康确认。
- 进程启动维护仅淘汰旧 TRIAL、保留 PENDING；候选失败恢复稳定 current。缓存读取不得排在完整网络同步之后；校验通过后提交 State 的短临界段仍复核 epoch/decision/精确版本。
- App ID 物理隔离；相同 SHA 不跨 App ID 共享对象。
- Manifest 是完整快照；V2 只变化一个 Bundle 时只下载/写入一个缺失对象，不复制另外 99 个。
- embedded Bundle 直接读取 HAP rawfile；`embedded.json` 只描述身份，不复制 bytes 到 OTA Store。
- Object 校验后原子发布，Manifest durable 后最后提交 State；State 是唯一激活点。
- 对文件和父目录的 `fsync`、rename、transaction recovery、`.part` 清理和 prune roots 是耐久性契约，不能为了简化删除。
- 有效 `transaction.json` 在恢复前保护已经发布的 CAS Object；成功提交后才清理事务目录。
- 启动/前台全量同步、页面 30 分钟后台检查、缺包修复和首屏回滚语义与另外两端一致。
- Server/Contracts 已支持 harmony；query/Manifest/State 固定 harmony，不再允许 `serverPlatform=android` 降级。
- 原生注册/清除用 `registerOtaUserId/clearOtaUserId`；同步 box 注册增 epoch，同身份不重复同步。HTTP 精确为 `versioncode`、`lynxSdkVersion`、可选 userId，匿名省略 userId。
- 构建码来自宿主自身 BundleInfo.versionCode，SDK 来自实际 HAR 的 LynxEnv.getLynxVersion()；不采用固定 BUILD_NUMBER、不伪装 Android。Models 只校验，不猜原生值。
- Server 用户/兼容过滤后 full7 胜 gray6；releaseSequence/policyRevision 用十进制字符串精确比较，不能转 Number，高修订允许回滚低序号。
- State v3 ref 保存 selection，State 保存 lastDecision/selectionSchemaVersion；unknown 旧 ref 必须新确认。full/gray 都检查 native/SDK 范围，gray 额外检查 audience，不建用户 bytes 目录。
- 每次 async 操作显式传只读 captured context 到 HTTP/Store/commit，禁止全局可变 operationContext 跨 await。最后同步 State rename 前校验 epoch/revision，与同步注册之间没有 await。
- 整批元数据先校验，再逐 App 独立落决定，最后下载；partial failure 不跳过其他 App 的撤销，也不伪报全量成功。
- 完整100包只变1时下载/新增1、复制0；事务和 lease 为 GC roots，后续成功退休已结束事务。有界历史回滚遇到已GC对象允许补缺，不无限存历史。

### 4. Page/Tab lease 与生命周期

- Page/Tab 读取 downloaded Bundle 时必须持有 lease；销毁、刷新、错误和过期异步结果都要释放。
- NavigationSnapshot lease 与页面 lease 分开管理；同一 session 不得在 current 切换后漂移到新 Manifest。
- Tab 普通切换 cache-only，不联网；后台不重建。身份/主动刷新完成后按有效 epoch reset Snapshot/generation 并重读已提交 State，包含 partial failure。
- delete 只清远程 OTA 内容，不删除 HAP rawfile；活体 lease 保护对象直到最后一个消费者释放。
- 首屏失败最多回滚一次；第二次失败显示明确错误，不无限重试。
- 页面与 Snapshot 绑定 epoch/generation，旧回调不能借当前身份新建导航或回滚新 current；旧 lease.close 不受身份失效阻止。

### 5. Bridge 与平台能力

- `LynxShellModule` 方法名、参数、结果码与三端 `BRIDGE_CONTRACT.md` 一致。
- UI/Router 操作进入正确的 ArkUI/UIContext；网络和磁盘不能阻塞 UI。
- 不支持的 Picker、上传下载或原生转场能力返回稳定 `1004`/降级原因，禁止假成功。
- 原始 Module 成功码是 `code=0`；页面 wrapper 归一化规则不在 HAR 内重复实现。
- 不在 main-thread 高频动画函数里调用 NativeModules、网络或 Router。
- GlobalProps 的宿主保留字段不能被业务 params 覆盖。

### 业务事件与监控

- `reportBusinessEvent(group, name, attributesJSON, callback)` 使用普通 Module 的 callback 语义；成功只表示实际进入 Core 队列，不代表 Provider 或云端收件。
- 所有事件顶层必填 `group`，Schema 固定 1.0。系统采集器填写默认组；业务 group/name 保留原文，只拒绝空或全空白，不维护业务枚举或注册白名单。
- 业务属性 key 非空，value 只允许 string、finite number、boolean；字符串在入队前复用 `monitorSanitize`，不截断修复非法或超限输入。
- raw group/name/attributesJSON 合计及完整快照沿用 32 KiB 总预算，队列沿用 128 条/512 KiB；group 计入实际编码字节，不增加独立字段或数量上限。
- Context 必须先在 `ShellMessageHub` 登记，再与对应 entryID/ViewMonitorBinding 绑定。Page/Tab 销毁、刷新和重建配对解绑；不得用最后一个 View 或 OTA current 猜测身份。同 View reload 无可靠 load 归属时降为 exact_view。
- 业务 admission 在同一同步段检查 runtime、Provider capability、快照预算和实际 append；initializing/ready 可排队，关闭、失败、未配置或不支持时明确拒绝。
- 业务只淘汰最旧 performance/resource，预算不足时零删除拒绝；系统按 performance/resource、business、原兜底顺序淘汰并记录 Core 丢弃类型。
- `RuntimeProvider.record(event)` 签名不变；business 支持由 capability 声明，安装不强制该能力。LocalDiagnosticProvider 保存相同处理后的本地事件，不执行网络上报。

### 6. `BuildProfile.ets` 特别规则

- `BuildProfile.ets` 可能包含本机/宿主构建适配，视为用户工作区文件。
- 除非任务明确点名，不修改、格式化、覆盖或暂存该文件。
- 如果它与当前构建冲突，先报告差异和影响，不自行回滚。

## 安全与工作树

- 不把 token、Cookie、签名 URL、请求头、证书、私钥和签名配置写入源码、测试、日志或文档。
- 不提交 `.app`、HAP/HAR 构建产物、oh_modules、Hvigor cache、模拟器数据和生成 Fixture 二进制。
- 本地 HTTP 和 fault/pause/capacity 注入只允许在 TEST/显式调试配置下启用。
- 保留用户已有修改，尤其是 `BuildProfile.ets`；禁止 reset/checkout 覆盖。
- 不修改 `harmony/lynx_shell`，除非任务明确要求 Demo UI 或 HDC 运行态验收。
- Shell不得反向依赖Cap；默认build profile/Entry已显式装配独立Cap HAR，只经中性Host SPI接线。

## 修改后的最低验证

以下命令必须先取得当前任务对应授权。2026-10-05 本轮仅源码实施与有界独立审查，
61条手工用例全部未执行，未compile/parse/typecheck/checks/测试/设备；源码审查不证明视觉、FPS、GPU峰值或零泄漏。

```bash
# HarmonyOS 静态门禁
python3 harmony/scripts/check_harmony_shell.py --quiet

# HAR 构建
cd harmony
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleHar --mode module -p module=lynx_shell_kit@default --no-daemon

# 完整 Demo App 构建（仅任务涉及 Entry/运行态时）
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleApp --no-daemon
```

涉及 OTA、Router、Page、Tabs、delete、恢复、文件原子性或错误态时，还需在 DevEco emulator/真机用 HDC 验证。优先复用：

```text
scripts/ota-store-v3/run-harmony-fault-tests.sh
scripts/ota-store-v3/run-harmony-process-crash-tests.sh
scripts/ota-store-v3/assert-harmony-results.mjs
docs/harmony-ota-store-v3-test-report.html
```

受控 capacity/ENOSPC、HDC force-stop、模拟器和本地 Server 证据不能冒充真实断电、真实 OS ENOSPC、签名包或生产 CDN/TLS。

历史 user-gray/versioncode 分包例外：用户取消 Harmony 模拟器测试，真机本轮未验收；仅验证代码、host 自动/真实 HTTP、HAR/App 与 HTML。
该历史批次host-final3 mode=all 18/18（5真实HTTP）＋Core25/25，0失败/跳过；release HAR/App构建及静态90/0/0通过，见 [当前报告](../../docs/harmony-ota-user-gray-test-report.html)。HTML展示与设备验收须独立记录，历史v3 HDC报告不能充当本次设备证明。
匿名内置脚本必须传 `--target harmony --platform harmony --versioncode ... --lynx-sdk-version ...`，不传 userId；命令见 [Module 接入](../../MODULE_INTEGRATION.md#三端匿名内置-baseline-下载)。

## 交付说明

最终回复必须说明：

- 改动是否只在 HAR，是否影响 Entry Demo；
- 是否改变 Router、Bridge、OTA、Store schema 或平台降级语义；
- 执行了哪些静态、Hvigor、HDC 和故障验证；
- 哪些物理真机、签名、断电和生产环境边界未覆盖；
- 是否触碰或保留了 `BuildProfile.ets`。
