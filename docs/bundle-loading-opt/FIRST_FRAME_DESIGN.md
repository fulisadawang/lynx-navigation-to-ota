# 普通 Lynx Page 首帧交接技术方案

日期：2026-10-09。当前分支 `codex/bundle-loading-opt`，main 基线 `b3837d491069dd5409d78dad75276201c54edaa3`。本文件为方案与测试设计，未实施、未新增可执行测试、未构建或设备执行。

## 目标与判断

采用一次性首帧交接：来源页画面保持可见，目标普通 Page 继续真实加载，收到真实 SDK 首屏并通过原生绘制门禁后，一次性交接画面并释放视觉快照。复用现有原生 Router、Snapshotter、transition_overlay、Coordinator 与 Loading/Error，不新建导航系统、不预创建第二个长期 LynxView。

这个方案解决可见空窗，不保证 Bundle 解码更快。当前 Large 的 208.622 ms 是单次录屏观察；实际耗时优化另用分段时延和内存测量验收。Android/iOS 应保持相同交接合同，平台绘制确认分别实现；本次设计重点 Android，iOS 尚需专门核验，Harmony 暂缓。

## 已核实的接入条件

- 普通原生 MainActivity 可以通过现有 Runtime 捕获来源 Window；只有 shared/open-container 的 selector 需要来源为 LynxShellActivity。
- 当前 Page 布局已有 underlay、liveContent（含 Toolbar）、overlay，无需增加永久 View。普通 startActivity 没进入现有 transaction，是当前白底先显示的关键路径。
- 当前 onLoadSuccess 也会调用 Coordinator 的 onFirstScreen；真实 SDK onFirstScreen 与原生实际画面提交不能等同。
- 当前 targetFrameReady 是 64 ms + postOnAnimation 的启发式，不是严格 Surface 提交证明。
- 当前 ready timeout 默认 1000 ms，会降级并显露未 ready 的 liveContent；单加 fade 参数仍可能在慢场景露空白。
- SnapshotStore 的现有 64 MiB/64 entries/30 分钟 TTL 是 Store 引用边界；Bitmap 在入 Store 前已分配，反向转场票据可能持有到页面销毁，所以不能作为新增普通页快照的充分内存保障。

## 设计选择：一次性交接用途，复用基础设施

在现有 ticket 增加内部快照用途，区分 `ENTER_HANDOFF` 与既有高级反向转场资产。此为拟新增内部标记，不是现成 Bridge 参数。公开 `LynxRouter.open`、App ID/BundleName、Release/lease、SHA、identity epoch 和 generation 合同保持。

首轮只接当前三夹具普通 Page 入口验证。普通页交接完成后不得为返回保留这张临时图；返回继续走普通原生栈/返回策略。已有 shared/open-container/preset 保持原用途和资产政策，不因该功能额外捕获第二张来源图或统一提前清理其反向转场图。

显式 fade 是已有参数，可以作为接线原型；它默认的反向资产保留、timeout 与 callback 规则必须修正后，才满足本方案。首版用零额外动效的原子交接；若实测需要柔化，再评估短淡化。不得直接沿用默认 420 ms 动效并宣称加载更快。

首帧交接与动画开关分开：animated=false 或减少动态效果时，仍应保护目标首帧前的空容器，只是不播放额外动效。不能沿用现有 style=none 直接显露 liveContent 的规则。

## 正常路径

1. Router 在主线程接受打开事务，记录 generation/entry；来源页面继续显示。预算准入成功后，下一来源绘制机会捕获一张 Window 快照。
2. 捕获成功且来源、事务仍有效，启动目标 Page。目标初始化就在现有 transition_overlay 最上层挂载临时 source cover（同一张来源图），只抑制本次系统 OPEN 动画。目标 liveContent/Toolbar 在 cover 后保持正常 layout/draw 与 alpha=1，但 touch/focus/accessibility 暂时隔离。不要把目标 alpha=0 或 GONE。
3. 原有 OTA resolve/lease/完整性校验、Provider 后台字节读取和 Lynx 渲染照旧。快照只是画面覆盖，不提供 Bundle 字节、不改变 current 或 Release 固定快照。
4. 目标树具备真实 SDK 首屏和有效布局后，在 cover 仍存在时观察绑定 generation 的目标绘制/提交阶段；符合条件后在下一绘制机会撤 cover、恢复目标交互，再释放这个 ENTER_HANDOFF 的 token/视觉引用。目标继续持有自己的 OTA lease。

这里采用最上层 cover 而非原 underlay：underlay 在 liveContent 后面；目标 alpha=0 时只证明来源图提交，设为1又会提前盖住来源。顶层 cover 使目标能够真实绘制，同时仍不对用户露出未就绪内容。可以在已有 overlay 临时挂一只 ImageView，不新增永久 View、不复制第二张 Bitmap。

必须防止 cover 尚未挂载的新 Window 先露主题白底；不仅检查交接尾部，也检查目标窗口第一帧。Native Toolbar 和系统栏样式随交接统一处理，不能先出现目标 Toolbar、内容区再等待。FrameCommit 仍是提交观察而非屏幕显示证明；还要核准当前 Lynx 4.1 原生节点更新与 SDK 首屏的顺序，不能把仅包含来源 cover 的 Root 回调当目标就绪。

## 首帧门禁

交接必须同时满足：当前 Activity/事务/generation/identity epoch 有效；真实 SDK onFirstScreen 已到；目标 View attach 且非零尺寸；原生树进入有效绘制/提交阶段。

onLoadSuccess 仅记录加载阶段，不能单独放行 ENTER_HANDOFF。Native open 返回的同步 success 仅表示事务已接受，不能作为首帧成功。

Android API 29+ 且硬件渲染时，可采用 ViewTreeObserver.registerFrameCommitCallback 作为提交观察点；它证明帧已渲染并提交到 swap chain，**不保证此刻已在屏幕上显示**。必须确认观察的是当前 generation 的目标内容，不把只含来源 cover 的 Root 提交当作目标就绪。[Android FrameCommit 文档](https://developer.android.com/reference/android/view/ViewTreeObserver#registerFrameCommitCallback(java.lang.Runnable))

本工程 minSdk 26。API 26–28 或非硬件渲染需使用有效 layout/pre-draw 与后续绘制周期的可验证降级；OnPreDraw 本身只表示即将绘制，不证明已显示。现有 64 ms 定时可作为过渡实现对照，不作为最终证明。[Android OnPreDraw 文档](https://developer.android.com/reference/android/view/ViewTreeObserver.OnPreDrawListener)

最终无白验收依赖原始录屏/实际帧；日志负责解释阶段，不能替代画面证据。不要求业务请求全部完成才允许显示一个有内容的首屏，也不把本例计算 READY 自动推广成所有业务页的门禁。

## 状态与错误处理

| 状态/事件 | 用户可见内容 | 操作与释放 |
| --- | --- | --- |
| 来源捕获中 | 原来的真实来源页 | 来源失效/Back 则取消；迟到捕获不启动目标 |
| 来源覆盖，目标未出帧 | 来源画面 | 目标不可点击/不可访问；系统 Back 取消目标，回来源 |
| 目标首帧满足门禁 | 真实目标内容 | 绘制提交观察后撤 cover；清 ImageView/token/监听器与定时器 |
| 捕获失败或预算不足 | 原生 Loading | 使用已有 ShellLoadingView，挂载可见内容后才露窗口；无 Bitmap 持有 |
| 视觉软超时 | 原生 Loading | Loading先在cover后真实布局/绘制，再撤cover/释放图；加载继续 |
| 模板/SHA/解析失败 | 原生 Error 与 Retry/返回 | 沿现有回滚一次与错误边界；先显示 Error，再撤快照；不把 timeout 当成功 |
| Retry | 原生 Loading | 新 generation；旧回调不交换；Error 隐藏前 Loading 已接管 |
| Back/关闭/身份失效 | 来源或已有安全错误态 | 取消目标准备、监听和动画；视觉快照与 pending 资源各按职责释放 |
| 配置重建/后台/进程恢复 | 来源覆盖或 Loading | 重建沿用有效 deadline，不能循环续期；进程无图时显式降级 |

视觉软期限首轮沿用现有 1000 ms，含义是停止冻结来源画面并改为 Loading，不是把 1000 ms 当加载失败。最终业务失败由现有 Provider/SDK 错误与既有 timeout 决定；本轮不额外发明无运行依据的硬失败阈值。

Loading/Error 在快照撤除前必须已经 attach/layout，并在对应绘制周期完成交接。不得进入现有“target_not_ready 就强制淡入未就绪 liveContent”的分支。捕获失败策略同样要保护新窗口第一帧，不能只把默认白底改成灰底当完成。

当前 ShellErrorView 只有 Retry，没有独立返回按钮。等待/错误态必须保留 Activity 级取消/返回出口：即便 fullscreen=true、无Toolbar、页面请求 backGestureEnabled=false，也不能把未成功进入的错误页困住。临时允许系统Back取消/finish；成功交接后恢复页面原Back策略，Retry进入新等待状态而不能误继承错误态。该改变只作用于未成功交接的等待/错误状态。

ENTER_HANDOFF 不取得长期自定义POP所有权：只抑制OPEN，不安装API34+的永久CLOSE无动画覆盖；若现有复用路径安装了CLOSE覆盖，终态要清除它并detach一次性ticket/transaction关联。Toolbar、系统与预测返回恢复普通路径；高级shared/open/preset不做这种清除。只释放图片不足以恢复返回语义。

## 内存与交互约束

- 每个普通交接只允许一张来源全屏 ARGB_8888 图；不创建目标截图或共享元素裁剪图；不得并发重复捕获。
- 当前 1080×2400 的理论像素缓冲为 10,368,000 B（约 9.89 MiB）。这是单个 source Bitmap 的像素量，不是总内存峰值；GPU/Surface/捕获额外成本仍需实测。
- Bitmap 创建前用 Long 计算 w×h×4，预留额度，创建后核对 allocationByteCount。现有先分配再 put/LRU 检查不够。
- allocationByteCount 超过预留值时，发起PixelCopy前在同一锁内补足差额；补额失败就放弃此图并降级Loading，不允许带超预算图进入复制。
- 额度同时覆盖待完成捕获与已缓存/显示的图，并与现有 Store admission 使用同一锁。PixelCopy 的逻辑超时/取消不等于平台复制已停止；仍在途的 Bitmap 不主动 recycle、额度不虚假归零，迟到结果不展示，只完成清理。未完成捕获占名额期间后续交接走 Loading，避免同时分配第二张。
- 初始建议：单次交接额度不超过 16 MiB，活动 ENTER_HANDOFF 最多一张，并受现有总快照额度约束。16 MiB 为待设备测量确认的方案值；低内存/额度不足走原生 Loading，不为抢名额驱逐仍在显示的高级转场图。
- 成功、Loading 降级、Error 交接、取消/销毁和晚到捕获均有明确释放。清 View/Store 引用，不在 RenderThread 仍可能使用时主动 recycle。Bitmap 与 OTA Release snapshot/lease 是两套不同生命周期，不能一起提前释放。
- 进入完成的普通页面，其 ENTER_HANDOFF retainedBytes 必须为 0；连续压栈不累计每级截图。既有高级返回图单独计数，不能混成“所有图都立即清”。
- 来源图只是视觉，不可点击。等待时隐藏目标 touch/focus/accessibility，交接或 Loading/Error 后恢复；避免透明目标提前响应点击。

## 改动落点

| 文件/边界 | 拟修改责任 |
| --- | --- |
| LynxNavigator / LynxTransitionRuntime | 普通交接接入、用途识别、来源有效性检查、单捕获与取消；原生栈保持 |
| LynxTransitionSpec/ticket | 内部 ENTER_HANDOFF 生命周期用途；明确与高级反向转场的区别 |
| LynxShellActivity | 区分 loadSuccess/真实首屏；提供绘制观察点；Loading/Error/Retry 与交接顺序 |
| LynxTransitionCoordinator | 等待/交接/软超时/取消的可观察状态；一次性终态；禁止未ready目标强制显露 |
| LynxSnapshotter / LynxSnapshotStore | 分配前额度准入、一次性交接专用释放与计数；原64MiB高级资产政策不擅自升级 |
| BundleLoadingManualDemo | 三夹具入口验证方案，保持同SHA/同Store；不把原型参数当已验证实现 |

不需要改模板业务、主包格式、Store完整性或主包读取优化。是否从试点推广到普通 Page 默认策略，必须在下面用例通过后再决定。

## 测试先行用例（未执行）

| ID | 输入/操作 | 必须断言 |
| --- | --- | --- |
| FF-01 | loadSuccess 先到，真实首屏未到 | 交换次数0，来源/Loading仍可见；不能假成功 |
| FF-02 | 帧信号先到/首屏先到，旧generation/epoch回调迟到 | 仅当前双门禁同时成立可交换一次 |
| FF-03 | slow目标跨过1000ms，稍后首屏完成 | 先Loading再释放图，后来正常显示；无空底/自动假失败 |
| FF-04 | PixelCopy失败/超时/预算拒绝/来源失效 | 禁止先分配超额度Bitmap；安全Loading或取消；晚回调不启动 |
| FF-05 | 捕获/prepare/等待帧/交换前后Back、销毁、后台 | 一次取消/终态，监听/定时器/图引用平衡；无迟到UI投递 |
| FF-06 | 同大小篡改/缺文件/解析错误及Retry | 原SHA/错误/回滚语义保留；Error/Loading交接有内容 |
| FF-07 | 原生源页与Lynx源页，Small/Large/Async冷/热打开 | 同SHA/同计算输出；来源完整画面到目标完整画面之间无“只有目标Toolbar、内容空白”的采样帧 |
| FF-08 | 连续20轮开/返回及多级压栈 | 普通handoff acquired-released=0、终态bytes=0；过程峰值有界；不能把引用归零冒充RSS立即归零 |
| FF-09 | shared/open-container/preset正反向，预测返回/配置变化 | 不重复来源图、不提前释放高级资产；原路由行为与返回状态保留 |
| FF-10 | animated=false/减少动态效果 | 仍等待真实首帧，不靠无动画绕过门禁；无额外动效但无空容器帧 |
| FF-11 | fullscreen+无Toolbar+backGestureEnabled=false时失败/Retry | Error可见，系统Back可退出；成功后恢复请求策略，Retry不残留旧错误状态 |
| FF-12 | handoff完成后的普通Toolbar/system/predictive Back | 无handoff自定义POP所有权或CLOSE覆盖残留，与原普通返回一致 |

先完成确定性 gate/预算/取消测试并在旧逻辑取得 Red，再实施；然后在模拟器记录至少每组30次正式打开（5次预热），覆盖冷/热与三固定夹具。无白断言依赖实际录帧，不使用任意固定sleep证明就绪。VFR视频按原始PTS与passthrough帧处理，不用转换后的固定fps序号推算时长。

记录 open、source capture、Activity创建、lease resolve、bytes交付、view创建、loadSuccess、sdkFirstScreen、target frame、handoff、release 的单调时钟。分别报告 capture、实际首屏、交接结束、snapshotHold及Bitmap峰值，防止动效/截图开销遮住真实加载变慢。

新增设计测试与构建需沿用户的后续实施授权执行；当前表格是验收合同，不是通过记录。真机低内存、API26–28降级、真实Graphics/RSS plateau仍需单独验收。iOS采用同用户可见合同并读其宿主代码设计，不照抄Android API；Harmony不纳入当前工作。

## 明确不采用的首轮方向

不先预加载全部Bundle、不创建隐藏长期LynxView池、不跳SHA、不扩大字节缓存；不把所有窗口改为透明Window；不为普通Page使用shared/open-container来绕出视觉效果。只改背景色可降低反差，但不是消除空容器或真实提速的证明。

方案已结合 Lynx 与 Android 专项的只读核验；修订了覆盖层层级、FrameCommit含义、CLOSE/POP所有权、错误页返回出口和真实分配补额五个问题。独立审查不是运行证明。当前风险集中在真实帧定义、新窗口第一帧保护、超时fallback、临时图释放与返回语义，必须先按用例验证。
