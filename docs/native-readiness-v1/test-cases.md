# 六项原生基座回归测试用例

日期：2026-10-03。版本：1。执行顺序：**用例先确定 → iOS 实现与验证 → iOS 完整报告 → Android 实现与验证**。

## 范围与验收契约

当前六项是：TRIAL 启动恢复、Page/Tab 故障处理、Cap 页面资源释放、Cap 执行线程与负载、真实能力状态/Host 适配、公共模块隐私与支持系统基线。

Harmony、Bundle 签名、Direct 入口限制、监控供应商接入和正式业务 App 最终发布包验收不在本轮。用户已授权编写/执行本轮回归测试及其必要本地构建；不授权 push、发布、生产数据或设备清数据。

以下是行为契约，不是当前已通过结果：

- Store v3 保持唯一激活状态；启动维护在首次页面读取前完成。冷启动遗留 TRIAL 清除，PENDING 保留；本进程正在试运行的候选不被普通同步再次清理。
- 候选缺少目标 Bundle 时不产生未实际加载的 TRIAL。候选的 lease、releaseId、identity epoch 必须一致。
- 普通 Tab 切换复用原 View 与固定 lease，不联网、不换包。初次实际加载或显式刷新可以试本地候选，不新增 Tab 模式开关；无候选读取 current。
- 健康确认采用真实首屏和显式业务信号 `markOtaHealthy` 两个事实，不加固定秒数。信号早到等待首屏，首屏早到等待信号。既有 `markTransitionReady` 继续只负责动画。
- 确认前的候选致命/模板错误：discard 并受控回落稳定 current 一次。稳定 current 的首屏失败最多回退 previous/embedded 一次。确认后 Fatal：停止失效页面操作、显示可退出/重试错误态，不自动回滚 current 或业务数据。普通资源错误不触发整包回滚。
- Cap 每个真实 Module/页面拥有独立 owner；换包重建产生新 owner。销毁时挂起 callback 恰好得到一次终态，后续完成无第二次回包，持续事件不再发往旧页面；其他页面保持。
- UIKit 和权限展示在主线程；磁盘/编码在固定有界执行器。callback 交付线程明确；不能同步等待主线程或在状态查询中等待异步权限。
- IO 输入、结果与 Base64 上限实施前在同一源中明确，测试参数从实际边界取值并覆盖 N-1/N/N+1；大媒体默认 URI，不默默把业务结果截断为成功。
- 状态查询保留现有逐方法目录；Host 不存在时写操作不可宣称 native；StatusBar.getInfo 只读 fallback 可用。权限查询继续使用各域 checkPermissions，不能把目录当成当前权限已授予。
- PrivacyInfo.xcprivacy 由实际使用 API 的 Pod 声明并打入资源；用途文案/entitlement 属于宿主。最低系统未运行时明确标记，不能以新系统通过替代。

## 用例与执行层

层级：**Core** 是真实文件 Store/Fake API 的 Swift Testing 或 Android 单测；**Host** 是真实生产类与可控系统替身的 XCTest/平台测试；**UI** 是本地测试 App 与真实 Lynx 回调；**Config** 是配置解析与构建产物检查；**Device** 是物理权限/硬件补充。

每行列出前置、步骤、预期和执行层。iOS 先填实际结果；Android 阶段沿用编号，差异在各自报告记录。

### 1. 启动恢复（7 项）

| 编号 | 前置与操作 | 必须观察到的结果 | 执行层 / 既有基础 |
|---|---|---|---|
| OTA-SEL-01 | 合法稳定 current；新 SDK/Runtime 离线走正式启动读取 | stable Bundle 可读；无下载、无候选状态改变 | Core + Host；OtaUserSelectionTests |
| OTA-SEL-02 | 当前旧稳定，候选 PENDING；新实例启动维护 | PENDING 保留；维护不擅自变 trial/current，实际打开才试运行 | Core；OtaCandidateActivationTests 新回归 |
| OTA-SEL-03 | 旧稳定 + 未完成 TRIAL；重建实例，走统一启动入口，不手调单 App 恢复 | TRIAL 清除，current 不变；多 App scope 均恢复；离线不再自动试旧 TRIAL | Core + UI 强杀/重启；原恢复单测只手动调用，不足以覆盖 |
| OTA-SEL-04 | Trial/State 提交前故障点；重建后启动维护 | 旧 current 不损坏，无半激活、无无限重试 | Core；OtaTransactionFaultTests + candidate 组合 |
| OTA-SEL-05 | 健康 promote 的 State 提交后终止；重建 | 激活唯一且幂等，previous 不重复覆盖，已提交健康 current 保留 | Core；fault tests + candidate 组合 |
| OTA-SEL-06 | A 候选在途/试运行，切 B；A 回调延迟 | B 不消费不兼容 A 灰度；迟到 A 不能修改 B State；当前身份/epoch一致 | Core + Host；OtaUserSelectionTests |
| OTA-SEL-07 | selected/Manifest/SHA 不一致，或候选缺目标 Bundle；读取/打开 | 拒绝损坏对象；候选无目标不先变 TRIAL；回退有界，lease 身份正确 | Core + Host；校验/lease tests + 新回归 |

### 2. Page / Tab / 健康与故障（7 项）

| 编号 | 前置与操作 | 必须观察到的结果 | 执行层 / 既有基础 |
|---|---|---|---|
| OTA-PAGE-01 | 本地 pending 候选；首屏与 markOtaHealthy 两种顺序及重复回调 | 两者齐全才 promote；只提交一次；单首屏/单信号均不确认 | Core 状态门禁 + Host/UI；新增业务健康契约 |
| OTA-PAGE-02 | Tab 初次加载本地候选，随后切换/后台；显式刷新 | 初次/显式刷新可试候选；普通切换复用实例/lease、无网络，无自动换包 | Host/UI；更新旧 current-only 用例契约 |
| OTA-PAGE-03 | 未确认候选失败；稳定 current/previous可用；重复失败 | 候选discard，稳定current不被误rollback；最多一次恢复；迟到确认不能覆盖失败 | Host/UI；原首屏回滚与generation测试 |
| OTA-PAGE-04 | 稳定current首屏失败，无previous；合法embedded | 最多一次embedded回退；无错误循环；目标未内置则明确错误态 | Core + Host/UI；原 embedded 用例 |
| OTA-PAGE-05 | 已确认页面写测试Preferences/SQLite；随后Fatal | 错误态与退出/重试有效；current与测试数据不自动回滚；旧View失效 | Host/UI；新增首屏后Fatal |
| OTA-PAGE-06 | 页面稳定后图片/字体资源失败或Warn | 不回滚Release，不拆掉正常页面，不影响其他Tab；错误保留分类 | Host/UI；实际 LynxError 分类 |
| OTA-PAGE-07 | 转场/恢复中取消、重复错误、旧generation或旧epoch的health迟到 | 只有当前generation/epoch操作生效；终态/确认/lease关闭各一次 | Host；可控异步调度，不以sleep冒充同步 |

### 3. 页面 owner 与取消（7 项）

| 编号 | 前置与操作 | 必须观察到的结果 | 执行层 / 既有基础 |
|---|---|---|---|
| CAP-OWN-01 | A发起未完成能力，destroy后任务返回 | 待完成callback收到一次HOST_DESTROYED或明确取消；无第二次成功，旧事件停止 | Host；真实Runtime+deferred任务 |
| CAP-OWN-02 | Cancel、自然完成和重复完成竞态 | callback恰好一次，终态唯一 | Host；once gate行为测试 |
| CAP-OWN-03 | 重复release/destroy/宿主消失 | 清理幂等；无重复取消/崩溃；其他owner保留 | Host；Runtime资源观察 |
| CAP-OWN-04 | A/B相同callback/listenerID，销毁A | 事件各归原owner；B持续，不被A释放 | Host；双Module/事件记录器 |
| CAP-OWN-05 | generation1有在途结果，原位换包生成2 | generation1迟到结果不能进入2；1取消，2可正常工作 | Host/UI；Tab generation + Cap owner |
| CAP-OWN-06 | A/B都保持屏幕唤醒；释放A再释放B | A退出不覆盖B；最后租约释放恢复先前App状态；无额外App任务架构 | Host；KeepAwake共享租约 |
| CAP-OWN-07 | 权限/相机/扫码/分享等待系统结果，先销毁页面 | 无失效presenter访问；结果不串新页；UI关闭，系统迟到回包安全 | Host替身 + 可运行UI；Device仅补充 |

### 4. 线程、并发与负载（6 项）

| 编号 | 前置与操作 | 必须观察到的结果 | 执行层 / 既有基础 |
|---|---|---|---|
| CAP-IO-01 | 主线程发起大文件读写/图片编码，并调度主线程heartbeat | 工作线程非主；UI/回包线程正确；heartbeat可先于受控未完成IO运行 | Host；真实executor与媒体路径，非源码字符串断言 |
| CAP-IO-02 | 提交超过并发上限的受控任务 | 峰值不超过实现约定；队列有界，超出明确失败，不无限new Thread | Host；可控开始/结束计数 |
| CAP-IO-03 | 空、N-1、N、N+1文件/Base64/结果 | 边界一致；超限结构化失败，无残缺目标或巨大成功JSON | Host；实际边界常量；URI大媒体 |
| CAP-IO-04 | 任务排队/分块途中销毁owner或cancel | 尚未开始工作不执行；在途可取消点结束；无临时文件/第二回包 | Host；隔离测试目录 |
| CAP-IO-05 | 在途任务后台/恢复，期间换owner | 生存任务按契约处理，旧页面无回包，新页面不被覆盖 | Host/UI；模拟器与真机后台差异单列 |
| CAP-IO-06 | 损坏图、截断文件、超时/网络错误/非法输入 | 稳定失败码，不崩溃、不空对象假成功、不无限重试 | Host；注入错误与本地fixture |

### 5. 真实能力状态与Host（5 项）

| 编号 | 前置与操作 | 必须观察到的结果 | 执行层 / 既有基础 |
|---|---|---|---|
| CAP-STATUS-01 | 当前catalog/adapter/provider组合；查逐方法状态并调用对应方法 | 状态与实际实现一致；方法/域总数顺序保持；native不等于权限已获批 | Host；semantic-catalog + 原生查询 |
| CAP-STATUS-02 | 无Host，再安装真实/fakeHost；查状态、StatusBar读写/SystemBars/Orientation | 无Host写方法partial/不可用；getInfo fallback可读；有Host时操作归正确容器 | Host + Sample adapter/UI |
| CAP-STATUS-03 | 可控权限拒绝/配置缺失/取消 | 明确权限或配置失败，不假成功、不反复弹窗；同步status不等异步权限 | Host替身；实际Device权限另外记录 |
| CAP-STATUS-04 | 可选硬件/系统能力不可用 | 明确unsupported/partial；不碰不可用API，不猜全局Window | Host；availability/device替身 |
| CAP-STATUS-05 | 真实transport收非法JSON/plugin/method/参数 | envelope稳定，callback一次，无新后台任务，消息不泄露真实数据 | Host；真实Module→Runtime路径 |

### 6. 公共模块与宿主基线（4 项）

| 编号 | 前置与操作 | 必须观察到的结果 | 执行层 / 既有基础 |
|---|---|---|---|
| HOST-BASE-01 | 自有两Pod隐私清单/实际API；Debug/Release资源构建 | 源清单可解析、用途有官方理由；两份PrivacyInfo资源进入对应产物，无重复plist根key | Config + Build；不是App Store通过证明 |
| HOST-BASE-02 | 最小测试Host缺一项用途文案，调用相应能力 | 调用前明确配置失败，不进入会被系统终止的权限请求 | Host；专用Bundle，不改正式宿主 |
| HOST-BASE-03 | 当前冻结依赖/最低系统与可选API | 声明一致；API availability受控；iOS14物理运行不可用则BLOCKED，不能用18/27代替；Android阶段另定24/26和JVM | Config + Build + 可用平台；最低运行差异记录 |
| HOST-BASE-04 | map-free E2E Host接Shell+Cap，真实创建多个LynxView并reload | Module注册可用，实例按View隔离，销毁接口实际被调用；不重复打包/替换SDK | Host/UI + Build；不宣称所有146方法已实测 |

## 执行映射与证据规则

1. Core：`ios/OtaIOSSDK` 当前 Swift Testing，先baseline，再增加回归，执行 `swift test --no-parallel`。真实State/SHA/lease验证，不复制生产状态机到测试镜像。
2. iOS宿主：当前 `LynxShellE2EHost` 是无地图Simulator目标，避开现有地图SDK无arm64 Simulator slice的边界。为Cap精确行为新增必要的XCTest目标，复用真实Pod源码；不在Sample硬编码“自测PASS”。
3. UI：现有 `ios/Tests/UITests`、测试Lynx Bundle及本地fixture；观察真实首屏、health、错误态、网络计数、进程重建与Module销毁。
4. Config：两Pod清单、Podspec、Info.plist和实际构建资源。对语法/资源检查可以解析配置；对生命周期/线程不能以grep作为PASS。
5. Android：iOS报告完成且核心回归解决后，才开始Android源码和相同编号测试；复用Gradle/JVM与必要instrumentation，记录Android特有权限/ActivityResult/Bitmap限制。

结果只有四种：**PASS**（本轮实际执行符合预期）、**FAIL**（实际行为不符）、**BLOCKED**（环境/契约不可执行并说明原因）、**NOT RUN**（未执行）。历史报告不算本轮结果。每项附实际测试名、命令、环境、日志与源码指纹。

物理相机/通知/定位/生物识别、真实低磁盘/系统后台、正式App归档和iOS14运行如无环境，分别记录缺口。测试成功不承诺无泄漏/FPS或所有真实用户系统行为。

## 门禁

本文件完成并经前置审查后开始iOS生产源码。新增测试先捕获原缺陷或记录不支持的当前行为，随后修复并复跑；结果失败必须解决或按真实环境限制说明。生成 `ios-test-report.html` 后再进入Android；不以阶段接近结束为理由跳过关键失败。

## 真实模板 Bundle 的宿主验证（用户追加要求）

宿主/UI用例使用当前模板的 HomePage、OtaEcommercePage 和随产物生成的 Async 资源，通过本机本地 HTTP/IP 地址提供下载。不得以另写一个简化页面替代真实模板页面。Core状态/故障单测仍使用最小确定性fixture，实际下载与页面加载证据另行记录。

模板源：`/Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxAppPackagesAndTemplates/templates/lynx-template`。构建前核对工作树与现有脚本，产物记录源SHA/内容SHA/大小；服务使用空闲本地端口，不更改既有服务或发布到远程。

HTTP测试提供真实主/Async字节，记录latest与资源请求次数；离线、坏SHA和截断仅在本地fixture受控注入。模板必要初始化完成后调用健康接口；业务页面未完成初始化不能自动标健康。
