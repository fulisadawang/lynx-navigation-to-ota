# Android 原生基座补齐契约

日期：2026-10-04。本轮沿用先用例、iOS 报告完成后再实施 Android 的顺序。

## 启动、候选和页面链

`OtaSdk.reconcileUserContext()` 的首次执行和直接 `beginCandidateTrial` 都先完成一次启动维护。
V2/V3 清理当前 scope 中所有 App 的遗留 TRIAL，保留合法 PENDING；重复维护不把本进程
刚开始试运行的包清掉。V3 保留 selected 的 policy、身份、versionCode 和 Lynx SDK 校验。
目标 Bundle 的 lease 先取得，随后开始 trial，缺少目标页面不会产生未实际加载的 TRIAL。

健康确认在真实 `onFirstScreen` 和后台 JS `markOtaHealthy` 两个事实齐全后提交。
`onLoadSuccess` 和 `markTransitionReady` 继续只提供视觉/转场信息。首屏与业务信号无论
哪一个先到，都等待另一个；重复在途调用返回 1006，失效 View/代次或加载取消返回 1002，
Runtime/Store 确认失败返回 1003，与 iOS 一致。成功 envelope 为 `code=0, message="", data={confirmed:true,releaseId}`。
普通 current/Direct 为成功只读结果 `confirmed=false,reason="not_candidate"`；已确认的
本页可幂等返回 true。Core 不因此回滚业务数据库或 Preferences。

确认前候选失败只 discard 对应候选，并受控重建稳定 current 一次。稳定 current 的
首屏失败最多回退 previous/embedded 一次。确认后 Fatal 释放失效 View、进入可退出/
重试错误态，current 和已经提交的业务数据保持。图片/字体资源失败和普通 Warn 不触发
整包回滚。错误在 SDK 回调处复制 code/subcode/fatal/level/message，再进入 UI 线程。

普通 Tab hide/show 复用原 Fragment、View 和 lease，不联网、不自动换包。首次实际
加载或显式 `refreshFromCurrent()` 才可试本地候选，保留现有方法名。

页面链使用独立、进程唯一的快照 ID，包含进程 nonce、逻辑 session 和唯一版本身份。
来源通过受保护 Intent extra 传递，业务不能用路由参数覆盖。活体页面分别持有 lease；
失败或身份变化让来源快照退休，停止接纳新页，最后一个页面归还后移除快照。已确认
快照和 embedded 快照同样固定版本。旧进程的 nonce 只恢复稳定 current；本进程已退休
来源不能借恢复路径重新打开。

State 提交在 `BEFORE_STATE_COMMIT` 故障点后、持久写入前检查线程中断。取消先到则不
提交；进入提交点后再关闭页面，不撤销已经完成的健康激活。

## 能力 owner、执行线程和负载

当前 Lynx 4.1 Android 的 `LynxModuleWrapper.destroy()` 实际转发 Module.destroy。
沿用 SDK 的 View→TemplateRender→ModuleFactory 销毁链，不增加 iOS 的专用销毁钩子。
`nativeLifecycleTryTerminate` 尚未成功时 SDK 会延后重试，View.destroy 返回不代表原生
销毁已完成；资源测试通过回调和真实 Window 状态等待完成，不能用即时读 flag 冒充屏障。
每个 Module 独立 owner，挂起调用终态在主线程交付时决定一次；销毁、取消、正常完成
不能产生第二次回包。旧 listener、权限/ActivityResult、定位、音频和 UI 资源按调用来源
释放，迟到结果不能进入新页面。

KeepAwake 和 PrivacyScreen 对 Window 使用 owner 租约；最后释放才恢复原状态。系统权限
请求无法由 App 撤销时，退休 requestCode 继续占位直到真实系统回调到达，避免串给新请求。

本地 IO 和网络各使用固定执行器：并行 2、排队 16，编码完成后再归还执行槽，超出
队列明确失败。磁盘、数据库、媒体编码和 ContentResolver IO 在工作线程；权限/UI 与
callback 在主线程。同步能力状态查询只读目录和安装快照，不创建 Host 或申请权限。

| 负载 | 真实上限 |
|---|---|
| 单个 transport 请求 UTF-8 | 1 MiB |
| 文件/媒体 inline 原始数据 | 512 KiB |
| 结果 JSON UTF-8 | 2 MiB |
| FileTransfer 下载 | 20 MiB |
| 需要解码/编码的图片 | 最大边 4096 pixels，16,777,216 pixels |

超限明确失败，不截断成成功。数据库逐 cell、URI 集合逐项、目录逐 entry 检查结果预算；
媒体分块复制检查 owner 取消，失败删除未提交项。原图直接返回 URI 不等于执行了图片
解码预算，也不能据这些上限宣称整体峰值内存无风险。

FileTransfer 写本地文件通过同目录 `.part` 发布，取消/失败保留原目标文件。`content://`
目标无法提供同样的原子发布语义，本轮明确 UNSUPPORTED；应用私有文件可返回 FileProvider
URI。正式调用方应按该平台差异选择目的地，不能把此变化遗漏为完全兼容。

## Host 适配和公共模块

能力 AAR 不依赖 Shell。公开 `LynxCapacitorHostProvider` 包含 supportedMethods、按
callerContext 的 resolve/release；Host.call 采用 plugin、method、options 和异步 completion。
Sample composition root 安装 provider，将调用 View 映射到 `LynxRouter.systemUIHandle`。
Runtime 必须在 Application.onCreate、首个 Activity 创建前安装。App.getState 读取实际
resumed Activity 的 App active 快照；后台未销毁的 Activity 不代表应用正在前台。

System UI handle 核实当前真实 View 与 Activity。Tab 被隐藏时恢复它实际修改的 Window
状态，重新激活时恢复已确认请求；销毁旧 owner 不覆盖当前页。系统栏操作以实际 Insets
可见性为结果，方向以 requestedOrientation 和实际横竖 configuration 一致为结果，最多
等待 2 秒；系统拒绝返回失败。反向方向不能由该窗口事实确认，明确 UNSUPPORTED。
TextZoom 走真实 `LynxView.updateFontScale`，返回 `verification=lynx_view_request`；SDK getter
保留系统字体缓存，因此此返回不冒充文字最终布局的观察结果。

40 域/146 方法目录保留。Host 写操作为 partial/checkRequired，安装 provider 不代表
当前容器/权限/硬件全部可用。StatusBar.getInfo 保留只读 fallback，Keyboard 样式的
未接通方法继续明确不可用。

能力 Library 自带必要权限、非 exported Activity/receiver、FileProvider 和路径 XML。
Shell、Cap/Sample 统一 minSdk 26，Java/Kotlin target 都为 17，构建 JDK 为 21。
原 Shell 的 API 24 声明与实际 java.time API 26 不一致已纠正，不再承诺 API 24/25。
API 边界见
[Android Instant 官方说明](https://developer.android.com/reference/java/time/Instant)。
Cap 的 java.nio/java.time 路径要求不能用降低声明规避。
当前根 AGP 已由 8.5.2 对齐到 8.9.1，满足现有 CameraX 1.5.1 与 compileSdk 36 基线，依据
[官方工具最低版本表](https://developer.android.com/studio/releases#api-level-support)。
JVM/AAR/Manifest 结果与 APK、最低系统、
真实设备/FPS/泄漏分别记录，不能相互替代。
