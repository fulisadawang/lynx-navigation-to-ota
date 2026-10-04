# iOS 原生基座补齐契约

日期：2026-10-03。当前是本地实施/测试，不是正式业务 App 发布验收。

## OTA 启动与健康

`LynxOtaRuntime` 在 prepare、resolveCurrent、resolvePage 的首次读取前等待统一身份/启动维护。
SDK 启动维护只运行一次，清除本地所有 App 的遗留 TRIAL，保留 PENDING。公共 SDK 的
beginCandidateTrial 也先完成该维护，随后不能把本进程刚建立的 trial 当成遗留版本清掉。

候选缺少目标 Bundle 时不变成 TRIAL；先取得目标 lease，再在同一短事务开始 trial。
普通 Tab 切换复用 View 与 lease。初次实际 load 和显式 refresh 允许读取本地 candidate，
不因此联网。原 `refreshFromCurrent` 名称保留兼容，不能理解为仅 current。

新增 `NativeModules.LynxShellModule.markOtaHealthy(callback)`，只允许后台 JS 调用。
它通过真实 LynxView 的 MessageHub endpoint 绑定 generation、releaseId 与 identity epoch。
候选必须同时满足真实 `lynxViewDidFirstScreen` 和业务初始化健康信号，才允许确认。
早到信号等待另一事实，不以固定秒数代替业务健康；markTransitionReady 仍仅负责动画。

- 成功：`code=0, message="", data={confirmed:true, releaseId}`。
- 普通 current/Direct：`code=0, message="", data={confirmed:false, reason:"not_candidate"}`，没有写 OTA 状态；本页已确认后的重复调用可幂等返回 true。
- 页面失效/换包：1002；重复在途确认：1006；真实确认失败保留失败消息。

模板 `AppRoot` 的 `otaReady` 默认 false。当前真实示例页的首屏初始化为同步，所以 entry 显式
传 true。业务模板加入必要异步初始化时，应由实际完成状态驱动 otaReady，而不能用组件挂载
代替完成。旧宿主通过实际方法探测保留原行为；新 Bundle 仍使用既有 App/SDK 范围发布。

未确认候选失败时只 discard 它并重建稳定 current 一次；另一个页面已经 discard 时只重读
安全 current，不误回滚后来版本。已确认后 Fatal 显示错误态、释放失效 View，不自动回滚
业务数据或 current。图片/字体等资源错误、普通非致命错误不触发整包回滚。

失败导航快照停止接纳新页，旧资源句柄继续保护文件直到归还；恢复创建稳定 current 快照。
子页接收来源快照身份，拒绝退休来源及同 App 不一致的返回快照，不能借新快照混入旧父页。
确认提交在 Store 的 beforeStateCommit 故障点之后、持久写入之前检查取消，期间无 await。
取消先到检查点则不提交；已经进入提交线性化点的确认不因稍后的页面关闭自动撤销。

## Cap owner 与执行

每个 Module 具有独立 owner。destroy 终结挂起 callback 一次、停止旧 GlobalEvent，
迟到完成不能覆盖新页。UI 控制器、Motion、音频与系统遮罩按 owner 清理；共享 KeepAwake/
Battery 采用租约，最后 owner 恢复 App 原值；SQLite 共享连接不随任意页面盲目关闭。

当前 Lynx 4.1 的 `LynxModuleDarwin::Destroy` 为空，不能假设声明 Module.destroy 后 SDK 自动调用。
宿主使用 `LynxRouter.registerNativeModule(LynxCapacitorModule.self, onViewDestroy: LynxCapacitorModule.destroy(for:))`。
Shell 各 View 出口统一经过 `LynxNativeRuntime.destroy(view:)`，先标记 Context 已失效并执行
一次宿主回调，再 clearForDestroy；Shell 不反向依赖 Cap。晚创建的 Module 立即释放失效 owner。

IO/数据库/媒体与网络分别使用有界执行器，各并行 2、排队 16；结果编码完成后才释放槽。
UIKit/权限展示保留主线程，磁盘/编码不阻塞主线程。预算是明确失败边界，不截断成假成功：

| 负载 | 上限 |
|---|---|
| 单个 transport 请求 UTF-8 | 1 MiB |
| 文件/媒体 inline 原始数据 | 512 KiB |
| 结果 JSON UTF-8 | 2 MiB |
| FileTransfer 下载文件 | 20 MiB，URI 与 inline 分离 |
| JPEG/thumbnail 像素 | 16,777,216 pixels，最大边 4096 pixels |

文件表示先通过 ImageIO 查尺寸、下采样，再编码。系统已提供 UIImage 时，编码前检查预算。
该检查不能证明 UIImagePicker 系统交付原图前的峰值内存，也不能据并发上限承诺无 OOM。

## Host 与诊断

Shell 与 Cap 保持独立 Pod。Cap 提供公开 Host provider，Sample composition root 将其映射到
Shell 中性的 LynxSystemUIHandle；normal 操作验证源 View、注册和窗口，release 只恢复原 owner。
方向操作等待实际 Scene 满足请求，UIKit 拒绝、失效或超时返回失败，不把请求发出当作已旋转。

同步 capability 查询只读实现目录和安装时快照，不碰 UIKit、不等待异步权限。
hostConfigured 与 runtimeAvailability 分开，Host 写方法保持 partial/checkRequired；
StatusBar.getInfo 保留只读 fallback。SystemBars 的 iOS 样式范围为 status_bar_only；
SafeArea 控制系统栏可见性，不宣称改写 Shell 实测的安全区域数值。

## 隐私与运行边界

Shell/E2E Core 和 Cap 分别携带自己的 PrivacyInfo.xcprivacy。
Shell 包含内嵌 OTA，声明其真实 UserDefaults、运行时长、磁盘容量和文件 metadata 用途。
其可配置 OTA 网络会传输 UserID/DeviceID/交互/性能/诊断信息，按 App Functionality 声明且不跟踪。
Cap 泛化 HTTP 不臆造全部业务数据收集类别；正式宿主仍需按实际服务用途补全业务声明。

iOS 14 是项目声明的支持基线。本机 Xcode 27.1 Simulator SDK 最低部署为 15，测试命令的
临时 override 不改变持久基线，也不能证明 iOS 14 真机运行。真实硬件、系统后台、整体峰值
内存/FPS 和正式归档分别记录，不能以 Core/Host PASS 代替。
