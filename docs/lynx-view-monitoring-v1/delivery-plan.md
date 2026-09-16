# 研发拆解、能力探测与验收 v1.0

本清单是研发任务和完成标准，不是测试报告。G1 当前实现与验证结果见 implementation.md；设备运行态、真实错误金标准和 G2 仍按本清单推进。

## 1. 固定的研发边界

- 从正式 `main` 的 Lynx 4.1 基线新建研发分支；开工时重新核实 main HEAD，不覆盖用户现有 dirty 文件。
- 不读取或迁移旧 telemetry worktree；不 cherry-pick 旧监控实现。
- 只改三端基座的监控接线、新增独立构建工具，以及用于验证的 Sample/Bundle。
- 不修改用户 Server/Admin；不在公共依赖里加入 ARMS/Bugly 等厂商 SDK。
- 不改变业务 NativeModule、OTA Store、回滚或原生转场算法。必要的已校验 Bundle 身份透传要作为独立改动评审。
- 运行时模型以 [runtime-contract.md](runtime-contract.md) 与 [event.schema.json](event.schema.json) 为准；产物模型以 [build-and-symbolication.md](build-and-symbolication.md) 与 [artifact-manifest.schema.json](artifact-manifest.schema.json) 为准。

## 2. 任务分工与依赖

| 任务 | 责任角色 | 工作内容 | 前置 | 提交/交付结果 |
|---|---|---|---|---|
| R0-A | Android | 核实 V2 性能、V1 错误、Page/Tab、字段时钟、运行期 JS 错误覆盖及内存/卡顿开关 | 正式4.1基线 | API 与原始事件证据表，缺失字段清单 |
| R0-I | iOS | 核实 V2 协议、独立 Tab、原始错误帧、lease/embedded哈希、内存诊断 | 正式4.1基线 | 同上，明确 SHA 身份透传点 |
| R0-H | HarmonyOS | 核实公共 client 在 Page/Tab 的实际字段、线程、错误及内存/流畅度能力 | 正式4.1基线 | 同上，unsupported 不填默认值 |
| R0-B | 构建 | 用冻结工具链核实生产 metadata 捕获时机、每entry和chunk材料、真实帧key | 正式lockfile | 真实生产构建清单与metadata完整性报告 |
| R1 | 主研发 | 实现事件类型、只读 Bundle 身份、Provider契约、内存分发、诊断状态 | R0核心API结论 | 纯公共能力，不含厂商SDK |
| R2-A | Android | 在Factory、Activity、Fragment挂载/清理监控；从真实读取结果绑定hash | R1+R0-A | Android全入口采集和DiagnosticProvider证据 |
| R2-I | iOS | NativeRuntime共同创建接线；Page/Tab生命周期与iOS SHA透传 | R1+R0-I | iOS全入口采集证据 |
| R2-H | HarmonyOS | 公共client结构化投影；Page/Tab两入口身份/可见性/销毁 | R1+R0-H | Harmony全入口采集证据 |
| R3 | 构建/工具 | production capture、manifest校验、archive/provider模式、离线反解CLI | R0-B+R1 | 两个构建版本的真实双线程反解结果 |
| R4 | QA/集成 | 三端并发View、旧版本/回滚、错误风暴、关闭与性能开销验收 | R2-*+R3 | G1报告：样本、原始事件、映射、SDK字段覆盖 |
| R5 | 厂商适配 | 选定厂商的运行时与构建适配、平台图表配置、端到端验收 | 厂商选择+G1 | G2报告与可用第三方平台链接/查询说明 |

R0-A/I/H/B 可并行；R2-A/I/H 与 R3 在接口冻结后可并行；R4集成不能由单端绿灯代替；R5 不提前假定三端支持。

### 2.1 计划文件所有权

目录是新增代码的建议落点，文件名可以在实现时按平台习惯调整，但职责与公开契约不能漂移。

| 角色 | 所有文件范围 |
|---|---|
| Android | `android/lynx-shell/src/main/java/com/example/lynxshell/monitoring/`；现有 Factory、Activity、Tab 的最小接线；OTA prepare 的身份透传 |
| iOS | `ios/LynxShellKit/Monitoring/`；NativeRuntime、Page VC、LynxShell.swift 内 Tab VC；PreparedOtaBundle身份透传 |
| HarmonyOS | `harmony/lynx_shell_kit/src/main/ets/monitoring/`；公共client、Page/Tab、必要导出 |
| 构建 | `playground/plugins/monitoring/`；`scripts/lynx-monitor-artifacts/`；现有构建配置的插件接入 |
| 验证 | 新建专用 monitoring 验收 Bundle 与对应原生 Sample 入口；不得改业务页面来触发故障 |
| 厂商 | 各端 `integration/monitoring/<provider>/` 和构建上传适配包；选型后才加入明确依赖 |

每端SDK类型只存在平台接线/厂商适配；公共事件采用同一schema。三端不是共享一个可执行文件，不能把Kotlin或Swift类型直接跨Bridge传给ArkTS。

## 3. R0 必须产出的能力表

每行至少记录 SDK实际版本、平台/系统、原生容器类型、回调名称、字段样例、线程、是否可唯一关联、缺失原因、证据文件路径。

| 能力 | 文档/源码已知 | 研发必须证明 |
|---|---|---|
| 首屏与加载阶段 | 三端有PerformanceEntry通道；4.1以LoadBundle数据为主 | 实际lynxFcp及各阶段有效，加载与重载不双计 |
| 原生整体打开耗时 | 需要extraTiming | 三端起点一致、时钟转换正确、缺失扩展字段不补零 |
| JS后台/主线程错误 | 有各端错误回调，主线程bytecode定位特殊 | 原始错误帧/release能被保留，显示后错误也能采集 |
| Promise/异步错误 | 没有无条件全覆盖保证 | reject/throw分别触发并记录覆盖矩阵；遗漏明确说明 |
| 同View reload | 没有通用Shell loadId；identifier不是加载流水号 | 无认证关联键时进入ambiguous路径，不能根据URL/接收顺序假配 |
| 实例内存 | Android/iOS有主动查询文档 | 实际绑定instanceId，共享runtime去重、超时质量和调用开销 |
| Harmony实例内存 | 等价能力待核实 | 无接口时unsupported，不能使用App内存替代 |
| 卡顿/长任务 | 可见开关/Trace不等于统一线上指标 | 各端实际事件、采集成本、是否View归因；未通过不进公共量化面板 |
| 编译调试材料 | Rspeedy含DebugMetadata生成机制 | 同次生产构建能捕获完整材料，并匹配真实错误帧key |

若 R0 发现核心公开API或生产材料缺失，先修正实现前置问题再推进G1，不把“兼容性 smoke”标记为数据闭环成功。

## 4. G1 运行时验收矩阵

所有三端用例在同一版本专用验收 Bundle 上执行，至少 Page+Tab 两种承载。未支持的平台用例单列，不用其他平台结果替代。

| 编号 | 场景 | 必须满足 |
|---|---|---|
| V01 | 正常打开Page | created/start/resolve/first_content与性能事件可关联到实际产物；observed时间不冒充发生时间 |
| V02 | 正常打开NativeTab | 获得独立viewId/loadId，不能只覆盖普通Page |
| V03 | A/B两个不同Bundle并存 | 所有事件各自带正确hash；不存在全局版本标签覆盖 |
| V04 | 同Bundle打开两次 | 两个viewId；两个有效首次加载样本 |
| V05 | Tab隐藏后再显示 | 不新建load、不重复首次加载，隐藏期回调归属不漂移 |
| V06 | 预创建但未上屏 | 标记hidden/preload事实；不把无FCP当0或超时失败 |
| V07 | OTA current更新但旧View保留 | 旧View错误/性能继续带旧SHA与release |
| V08 | 首屏失败后既有回滚 | 错误属于旧load；回退产生新的实际产物身份；监控不调用rollback |
| V09 | 重试/刷新重建View | 新viewId/loadId，旧回调不进入新实例 |
| V10 | 同物理View原生reload | 没有认证关联键的事件loadId为空且明确ambiguous，不被记到最新load |
| V11 | JS直接reload | 同V10；不得用替换listener/URL相同推断准确归属 |
| V12 | 旧prepare晚到 | 继续按原有generation/epoch处理，释放旧lease；不创建或冒用新scope |
| V13 | close前入队、close后排出 | 事件仍保持原始身份，Provider正常处理 |
| V14 | close后才到SDK回调 | 不复活scope；有拒绝计数；无活体UI/lease滞留 |
| V15 | 首屏后JS异常 | 可采集运行期异常；不把加载成功改为失败，不强制回滚 |
| V16 | 同一错误连续触发两次 | 两个eventId和两次occurrence；同一SDK错误多入口转发只计一次 |
| V17 | 字段缺失/负哨兵/NaN | 不输出假的0ms，明确missing/invalid；第三方适配不崩溃 |
| V18 | 无Provider/初始化失败 | 状态明确，页面正常加载；没有假上传成功 |
| V19 | 两个验收Provider互换 | 重启后仅改注册配置即可；公共事件形状一致，无厂商SDK类型进入核心 |
| V20 | Provider拒绝/抛错/慢调用 | 不阻塞Lynx线程，不递归错误，不改变页面/OTA状态 |
| V21 | 队列/事件大小达到上限 | 内存有界；丢弃/截断计数真实；关键关联字段仍保持或明确unassigned |
| V22 | 模拟重载回调乱序 | 无唯一关联的数据不会进入构建版本统计；顺序不可用时不猜配 |
| V23 | 采样 | 同一View性能采样一致；错误不继承性能抽样；核心与SDK不重复采样 |
| V24 | Direct asset/HTTPS | SHA来自实际字节；没有发布版本就null；资源失败不伪造hash |
| V25 | 关闭/退出 | listener、scope、UI、lease分别释放；全局Provider不因单页退出被关闭 |

### 4.1 JS 分类故障

每类记录：是否收到回调、错误码、线程、是否带stack/key、原始定位类型、是否可还原；任一缺失都可复现。

- 后台 render / effect throw。
- 普通 bindtap throw 与 main-thread:bindtap throw。
- timer throw、裸 Promise rejection。
- NativeModule callback 内 throw/rejection。
- lazy Bundle 加载拒绝与其执行期错误。
- 被代码捕获但未报告的错误作为负例：不声称它被自动捕获。
- 图片/模板资源错误作为分类负例：不错误计入JS问题或启动主线程映射。

## 5. G1 构建与反解验收

| 编号 | 场景 | 必须满足 |
|---|---|---|
| B01 | production清理前捕获 | 构建后归档存在，App/Bundle发行目录不含调试材料 |
| B02 | 多entry+lazy脚本 | 每个实际脚本材料被索引，不只保存main的map |
| B03 | Bundle/metadata内容变化 | manifest哈希与实际文件一致，不能复用过期回执 |
| B04 | 后台文本JS错误 | 用同次source-map还原到已知源码位置 |
| B05 | 主线程bytecode错误 | 经过debug-info再source-map；不能将functionId当line |
| B06 | R1/R2两次构建 | 旧View错误查旧归档；源码位置改变仍不串版本 |
| B07 | 缺map/debug-info | 输出明确unresolved原因，双路径验收失败 |
| B08 | frame key与Bundle不符 | identity_mismatch，不选最新map猜测 |
| B09 | 同名脚本冲突 | 无唯一材料时ambiguous_artifact；不只按background.js匹配 |
| B10 | key跨entry合法共享 | 一致材料允许复用；同key不同材料拒绝覆盖 |
| B11 | 没有源码上下文 | 位置与片段可用性分开；不能从本机最新源码拼片段 |
| B12 | 未配上传Provider | archive可以成功；publish必须明确NOT_CONFIGURED |
| B13 | 上传只有部分成功 | 不生成完整indexed回执，发布关口失败 |
| B14 | 特殊/无法识别帧 | 保留原始帧与unresolved，不丢整条错误 |

## 6. G2 厂商选型与验收表

厂商选择前，以下全部为未确认；不写入“ARMS支持”或“Bugly支持”的预设结论。

| 核验项目 | 合格要求 |
|---|---|
| 三端SDK | 确认Android/iOS/HarmonyOS锁定版本及授权/平台支持，缺端显式披露 |
| 自定义性能 | 可带单位及Bundle构建维度，能查询有效样本、分位数或提供等价数据分析能力 |
| 自定义JS异常 | 原始堆栈、逐帧release/key/定位类型不会被SDK丢失或改写成原生异常 |
| 多View隔离 | 每事件或隔离scope属性；禁止临时切全局release后再恢复 |
| 普通JS映射 | 同构建map正确命中 |
| 主线程映射 | 原生支持Lynx debug metadata，或经真实验收的厂商转换路径；只收.map不合格 |
| 发送可靠性 | SDK采样/限流/缓存/重试可描述，核心不做重复网络提交 |
| 数据大盘 | 能按平台、Bundle、实际构建/发布查询性能与异常，并跳到原始/映射详情 |
| 历史版本 | 支持旧构建调试材料保留与回滚错误查询 |
| 隐私与材料权限 | 调试产物私有，SDK事件不带业务数据/令牌；源码访问可控制 |
| 异常影响范围 | occurrence计数与影响View数量分开，不把独立事件ID数等同用户数 |

厂商不满足时可以明确接受“部分能力”的产品边界，但不能把完整G2打勾。更换厂商只改适配器/初始化和构建上传配置，重新执行G2。

## 7. 性能开销与回归

以下是研发验收目标，不是已测结果；首次实现需记录设备、系统、构建模式、是否开启第三方SDK及采样率。

- 首屏关键路径不得新增网络/磁盘等待；所有Provider失败不影响页面完成。
- 公共回调加工与入队同步耗时目标 P95 ≤ 1 ms，在约定测试设备记录至少1000次样本；若超过先分析，不以放宽统计口径掩盖。
- 相同Bundle/设备/配置，监控关闭与开启各执行至少30次加载；分别记录FCP分布和新增内存，超出基线正常波动须评审后才接受。
- 公共事件队列满足128条/512KiB边界；关闭页面后scope计数回落，不以一次GC后的App内存不降直接断言泄漏。
- 本轮验证不扩大到业务API、支付和登录；保留原生路由、Tab、主题、i18n、OTA和转场回归。

## 8. 本轮设计检查与后续测试的区别

设计阶段已检查：文档链接、Schema 可编译、示例符合 Schema、反例被拒绝、跨文档字段和边界一致、文件改动范围。实现阶段的静态、构建和平台边界见 implementation.md。

Schema无法证明：文件真实SHA、SDK事件字段完整、三端行为一致、Source Map实际精度、厂商收到数据。上述必须按R0/G1/G2完成。

示例目录中的所有JSON都是结构示意，不是实测：

- [性能事件](examples/performance.example.json)
- [主线程错误事件](examples/js-error.example.json)
- [构建清单](examples/artifact-manifest.example.json)

归档内 path 对应的文件不随这些示例提供，不能拿示例SHA/size作为构建校验通过证明。真实验收必须使用R0/R3产出的Bundle、DebugMetadata与实际SDK错误。
