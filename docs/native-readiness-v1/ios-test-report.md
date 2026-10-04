# iOS 原生基座测试报告

状态：本阶段报告

iOS 本地软件门禁通过，可以开始 Android

Core 99 测试/12 suites 全部通过；Host/UI 68 个方法按最后结果去重后 67 通过、1 个物理电池用例跳过、0 个现存失败。36 项契约中 33 项在明确限定的软件范围内 PASS，3 项因真实后台、系统权限、iOS14环境 BLOCKED。完整批次与最后10项重跑分别保留，未把多个批次说成同批全通过。

Android 门禁：可继续；未覆盖项保留

## 六项归属

| 范围 | 负责层 | 契约 |
|---|---|---|
| 启动恢复 | Shell 内置 OTA | 在首次读取前恢复遗留 TRIAL，保留 PENDING，遵守身份与 Store 原子事务。 |
| 页面健康与故障 | Shell + 模板业务入口 | 真实首屏与显式业务健康信号共同确认；确认后的 Fatal 不自动回滚业务数据。 |
| 页面 owner 与取消 | Cap + Shell 销毁接线 | 回包和事件归属真实 Module owner；宿主注册销毁钩子，资源释放按原 ctx 精确执行。 |
| 线程、并发与负载 | Cap | UI 留在主线程；IO/编码进入有界执行器，超出负载预算明确失败。 |
| 真实能力与 Host | Cap provider + Host 组合根 + Shell 中性 API | 目录状态、运行时可用性和权限分别表达；源 View 决定操作与恢复的归属。 |
| 模块资源与系统基线 | Shell/Cap Pod + Host 工程 | 模块打入自己的隐私资源；用途文案属于宿主；声明的最低系统需要单独运行证据。 |

SDK 接线约束：Lynx 4.1 LynxModuleDarwin::Destroy 为空；clearForDestroy 不自动等于 Swift Module teardown。宿主注册 onViewDestroy，按原 ctx 释放 Cap，Shell Core 不依赖 Cap。

本轮排除：Harmony 补齐、Bundle 签名、Direct Bundle 入口限制、监控供应商接入、独立 Native 协议版本门槛、正式业务 App 最终发布包验收。

## 验收用例状态

36 项：PASS=33；FAIL=0；BLOCKED=3；NOT RUN=0。测试函数数量与验收项分开计数。

| 编号 | 结果 | 实际观察 | 测试名 / 证据层 | 未覆盖 |
|---|---|---|---|---|
| OTA-SEL-01 | PASS | Core + 真实模板 UI：稳定 current 可读取；本地 OTA fixture 返回 503 后重启仍显示 Home，主 Bundle 下载计数为 0。 | Core: current lease reads finish while a background latest download remains suspended（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log）；UI: NativeReadinessTemplateUITests/testRealHomeBundleDownloadsAndRendersFromLocalIP（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult） | 503 仅模拟本地 OTA 服务不可用，没有关闭模拟器全部网络；未覆盖真实设备全网断开。 |
| OTA-SEL-02 | PASS | Core + Host：新实例启动维护保留 PENDING，不自动 promote；缺少目标页面时候选仍为 pending。 | Core: OTA-SEL-02 startup preserves pending and never promotes it（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log）；Host: ShellOtaRuntimeReadinessTests/testCandidateWithoutRequestedTemplateBundleRemainsPending（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult） | 未穷举真实设备各类系统进程终止时机。 |
| OTA-SEL-03 | PASS | Core + 真实模板 UI：统一启动维护清除遗留 TRIAL，重复维护不清本进程活跃 trial；App.terminate 后 503 重启从 v2 trial 回到 v1 稳定页面。 | Core: OTA-SEL-03 selected startup maintenance discards interrupted trial without per-App recovery（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log）；Core: OTA-SEL-03 repeated maintenance in the same SDK does not discard its live trial（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log）；Core: OTA-SEL-03 direct SDK begin-trial runs startup maintenance before changing pending（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log）；UI: NativeReadinessTemplateUITests/testActualProcessTerminationDuringTemplateTrialRestoresStableOffline（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult） | App.terminate 是真实模拟器进程终止，不代表所有真机 kill、掉电或系统回收时机。 |
| OTA-SEL-04 | PASS | Core：State 提交前故障与 v3 Manifest 故障保留旧 current，重试能恢复；确认提交前取消保持 trial。 | Core: a failure before state commit keeps old current and can retry after restart（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log）；Core: v3 Manifest 提交故障不会发布半成品，重试可恢复（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log）；Core: cancelling candidate confirmation before its commit keeps the trial（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log） | 故障点为可控事务注入，未做物理掉电或真实低磁盘损坏试验。 |
| OTA-SEL-05 | PASS | Core：State 提交后幂等恢复与重复激活保持 previous；提交后的取消不逆转已确认 release。真实模板 UI 同时覆盖已确认 v1 重启继续读取。 | Core: a failure after state commit is repaired by idempotent activation（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log）；Core: replaying an activation after the state commit keeps previous stable（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log）；Core: cancelling after candidate state commit does not roll back the committed release（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log）；UI: NativeReadinessTemplateUITests/testRealHomeBundleDownloadsAndRendersFromLocalIP（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult） | 未覆盖每个底层文件系统提交指令间的真实进程终止/掉电。 |
| OTA-SEL-06 | PASS | Core 身份契约：A 迟到响应不能写 B State；旧身份的健康/失败不能改变下一身份 candidate；注册与最终提交之间有原子拒绝。 | Core: delayed A response after B registration cannot write state or return success（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log）；Core: late candidate health or discard cannot alter a candidate prepared for the next identity（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log）；Core: registration immediately before final State replacement aborts activation atomically（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log） | 跨身份的设备 UI/权限组合和长期压力未运行。 |
| OTA-SEL-07 | PASS | Core + Host：size/SHA 损坏被拒绝；MissingPage 读取不把候选变 TRIAL，State current 指针保持。State 的 embedded 指针和 App 资源 releaseId 分属两层，分别与操作前快照比较。 | Core: rejects downloaded bundle when manifest size does not match（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log）；Core: a tampered current file misses validation cache and is not returned（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log）；Host: ShellOtaRuntimeReadinessTests/testCandidateWithoutRequestedTemplateBundleRemainsPending（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult） | 未对真实模板下载 UI 单独执行坏 SHA/截断网络场景；相关校验在 Core 执行。 |
| OTA-PAGE-01 | PASS | Host 门禁 + 真实模板：两种信号顺序都只确认一次；单首屏或单业务信号不确认。真实模板实际首屏与显式业务信号使候选 promote。 | Host: ShellOtaHealthGateTests/testBothSignalOrdersConfirmExactlyOnce（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: ShellOtaHealthGateTests/testBusinessSignalAloneDoesNotConfirmCandidate（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: ShellOtaHealthGateTests/testFirstScreenAloneDoesNotConfirmCandidate（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: ShellContainerHealthIntegrationTests/testConfirmedPageFatalKeepsCurrentAndWrittenBusinessData（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult）；UI: NativeReadinessTemplateUITests/testRealHomeBundleDownloadsAndRendersFromLocalIP（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult） | 当前模板首屏初始化为同步；真实异步业务须按完成状态驱动 otaReady，未运行具体业务初始化。 |
| OTA-PAGE-02 | PASS | 真实模板 Tab UI + Runtime：首页/电商初次加载本地发布字节；多次切换保留首页实例，不增加 latest/main 下载。点击电商入口进入下载态 Async ProductDetail。 | UI: NativeReadinessTemplateUITests/testRealTemplateTabsKeepInstancesAndUseDownloadedAsyncResources（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult）；Host: ShellOtaRuntimeReadinessTests/testCandidateRecoveryReplacesOnlyFailedSnapshotAndKeepsSameSessionOnStableRelease（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult） | 显式 Tab refresh、真实系统后台挂起的组合未单独执行 UI 用例。 |
| OTA-PAGE-03 | PASS | 真实模板 Host：健康确认前 Fatal 丢弃候选并受控重建稳定页面一次；Runtime 恢复只替换失败 snapshot，另一页已 promote 后迟到失败不会回滚。 | Host: ShellContainerHealthIntegrationTests/testUnconfirmedCandidateFatalDiscardsOnceAndRebuildsStablePage（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult）；Host: ShellOtaRuntimeReadinessTests/testCandidateRecoveryReplacesOnlyFailedSnapshotAndKeepsSameSessionOnStableRelease（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult）；Host: ShellOtaRuntimeReadinessTests/testLateCandidateFailureAndConfirmCannotRollBackPromotedCurrentFromAnotherPage（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult） | Fatal 是在真实容器中注入的受控 Lynx 错误，不代表全部 JS/native 崩溃类别。 |
| OTA-PAGE-04 | PASS | 既有 Lynx UI 回归：稳定 current 首屏失败时可回退 previous；无 previous 时回退 embedded，恢复有界。 | UI: LynxShellUITests/testFirstScreenFailureFallsBackToEmbeddedBaselineWithoutPrevious（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；UI: LynxShellUITests/testFirstScreenFailureRollsBackToPreviousRelease（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 这两项首屏故障使用既有测试 Bundle；未对 Home/Ecommerce 再分别注入同一首屏故障。 |
| OTA-PAGE-05 | PASS | 真实模板 Host：健康后 Fatal 显示错误态、释放失效 View，current 与隔离业务 JSON 文件保留。数据库取消测试另证实不会随 owner 退出关闭共享连接。 | Host: ShellContainerHealthIntegrationTests/testConfirmedPageFatalKeepsCurrentAndWrittenBusinessData（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult）；Host: CapHTTPDatabaseTests/testSQLiteConnectionSurvivesOwnerExitAndBlobResultIsBounded（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 未模拟真实 Preferences/SQLite schema 升级及业务逆迁移。业务持久化/schema 必须兼容可回退版本，或把不可逆操作延后到健康确认。 |
| OTA-PAGE-06 | PASS | 真实容器 Host：受控 resource error 不拆除健康页面，generation/current 保持；错误分类不把资源失败当作整包 Fatal。 | Host: ShellContainerHealthIntegrationTests/testResourceErrorKeepsRealPageAndCurrent（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult） | 实际图片/字体网络服务故障与多 Tab 组合未分别注入。 |
| OTA-PAGE-07 | PASS | Core + Host：确认中失败拒绝迟到成功，旧 generation 健康事实不能复用，提交前/后取消语义明确；跨页面迟到确认不改变已 promote current。 | Host: ShellOtaHealthGateTests/testFailureDuringConfirmationRejectsLateSuccess（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: ShellOtaHealthGateTests/testFailureInvalidatesQueuedReadyAndHealthSignals（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: ShellOtaHealthGateTests/testNewGenerationUsesFreshGateWithoutOldHealthFacts（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: ShellOtaRuntimeReadinessTests/testLateCandidateFailureAndConfirmCannotRollBackPromotedCurrentFromAnotherPage（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult）；Core: cancelling candidate confirmation before its commit keeps the trial（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log） | 真实系统返回手势/转场中断与身份切换的联合 UI 压力未运行。 |
| CAP-OWN-01 | PASS | 真实 Runtime + SDK 宿主销毁接线：destroy 终结挂起回包一次，丢弃迟到成功及排队主线程交付；真实 Shell View 销毁按 ctx 释放 Cap Host 一次。 | Host: CapOwnerRuntimeTests/testDestroyCompletesPendingOnceAndDropsLateSuccess（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapOwnerRuntimeTests/testQueuedBackgroundResultIsCancelledBeforeMainDelivery（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: ShellSDKDestroyIntegrationTests/testActualShellViewDestroyReleasesCapHostExactlyOnce（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult） | 未逐一执行全部 146 方法的销毁期间回包。 |
| CAP-OWN-02 | PASS | Host 可控调度：自然完成、重复完成、销毁与迟到交付均只有一次终态。 | Host: CapOwnerRuntimeTests/testNaturalCompletionAndDuplicateCompletionHaveOneTerminal（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapOwnerRuntimeTests/testDestroyCompletesPendingOnceAndDropsLateSuccess（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapOwnerRuntimeTests/testQueuedBackgroundResultIsCancelledBeforeMainDelivery（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 真实硬件/系统服务的所有竞态与长时间压力未覆盖。 |
| CAP-OWN-03 | PASS | Host + 真实 SDK View：scope 清理幂等，精确 context destroy 保留其他 Module，旧 context 拒绝迟到创建；真实 View 销毁不重复释放 Host。 | Host: CapOwnerRuntimeTests/testScopeResourceCleanupOnlyClosesItsOwnerAndIsIdempotent（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapOwnerRuntimeTests/testExplicitContextDestroyKeepsOtherModuleAliveAndRejectsLateCreation（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapOwnerRuntimeTests/testFirstCallAfterContextDestroyedClosesExistingRuntime（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: ShellSDKDestroyIntegrationTests/testActualShellViewDestroyReleasesCapHostExactlyOnce（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult） | 未做长期内存图/泄漏或完整系统 UI 资源压力测试。 |
| CAP-OWN-04 | PASS | Host：相同 callback/listener ID 的调用按 owner 隔离；真实 Motion 注册表停止 A 不影响 B。 | Host: CapOwnerRuntimeTests/testSameCallbackIDDoesNotMixOwnersOrCalls（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapHostStatusTests/testActualMotionRegistryKeepsSameIDAndStopOwnedByEachPage（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 真实运动传感器高频持续事件和多页面长时压力未运行。 |
| CAP-OWN-05 | PASS | Host：generation 更换隔离请求与事件，旧 context destroy 拒绝迟到创建；旧结果不能投递到新 owner。 | Host: CapOwnerRuntimeTests/testGenerationReplacementKeepsEventsAndRequestsSeparate（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapOwnerRuntimeTests/testExplicitContextDestroyKeepsOtherModuleAliveAndRejectsLateCreation（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 真实 Bundle 反复 reload 的全方法组合压力未运行。 |
| CAP-OWN-06 | PASS | Host 租约协议：KeepAwake 和 Battery 可控驱动在最后 owner 退出后恢复原 App 值；A 释放不覆盖 B。 | Host: CapOwnerRuntimeTests/testKeepAwakeLastOwnerRestoresPreviousAppState（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapOwnerRuntimeTests/testBatteryMonitoringLeaseDriverRestoresOnlyAfterLastOwner（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 物理 Battery 监控用例在 Simulator 跳过；真实设备不熄屏/电池状态未运行。 |
| CAP-OWN-07 | PASS | Host UI/资源协议：owner overlay、正常 Video/Preview dismissal 与进度资源只归还本 owner；销毁期间 Orientation 迟到成功被拒绝，系统 store 修改在调用前取消。 | Host: CapHostStatusTests/testOwnerOverlaysReleaseWithoutRemovingOtherPage（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapOwnerRuntimeTests/testNormalVideoAndPreviewDismissReturnOnlyTheirOwnResources（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapOwnerRuntimeTests/testOwnedProgressTicketsReturnOnFinishAndHandleEarlyCompletion（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapHostStatusTests/testDestroyedOwnerCancelsOrientationOnceAndDropsLateHostSuccess（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapIOExecutorTests/testCancelledProviderMutationsRejectBeforeCallingSystemStore（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 真实相机/扫码/分享系统 UI 与权限弹窗的销毁回包，需要物理设备补充；未标记 Device 通过。 |
| CAP-IO-01 | PASS | 真实执行器/文件/媒体 Host：后台 IO 不堵塞主线程 heartbeat；文件回包线程符合约定，小 UIImage 在 IO pool 实际编码，ImageIO 文件先下采样再 JPEG。 | Host: CapIOExecutorTests/testExecutorDoesNotBlockMainHeartbeat（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapIOExecutorTests/testFilesystemReadAndWriteInlineBoundariesAndCallbackThread（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapIOExecutorTests/testSmallUIImageActuallyEncodesInIOPool（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapIOExecutorTests/testImageIOFilePathDownsamplesLongThinImageBeforeJPEG（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 没有整体 FPS、主线程卡顿 trace 或系统交付原 UIImage 前的峰值内存证据。 |
| CAP-IO-02 | PASS | Host：固定并发/队列容量拒绝超额工作；结果编码仍占执行槽；慢网络池不占本地 IO 的槽。 | Host: CapIOExecutorTests/testConcurrentAndQueuedCapacityRejectsOverflow（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapIOExecutorTests/testCompletionEncodingRetainsExecutionSlotUntilItReturns（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapIOExecutorTests/testSlowNetworkPoolDoesNotBlockLocalIO（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 未以长时间真实网络/文件负载衡量吞吐或设备峰值内存。 |
| CAP-IO-03 | PASS | Host 边界：真实文件/Base64/输入 JSON/结果/URI 与图片像素及边长界限按明确预算通过，超限结构化拒绝，不留下残缺目标。 | Host: CapIOExecutorTests/testFilesystemReadAndWriteInlineBoundariesAndCallbackThread（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapIOExecutorTests/testBase64WriteLimitsAndInvalidDataFailWithoutTarget（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapIOExecutorTests/testInputJSONExactLimitAndOutputLargeResult（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapIOExecutorTests/testMediaURIHasNoInlineLimitAndBase64BoundaryRejectsExplicitly（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapIOExecutorTests/testImagePixelAndEdgeBoundariesWithoutAllocatingLargeBitmaps（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapHTTPDatabaseTests/testHTTPStreamEnforcesDeclaredResponseLengthBeforeBuffering（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 未构造最大真实相机位图或全部外部传输尺寸组合；预算不等于无 OOM 保证。 |
| CAP-IO-04 | PASS | Host：排队工作在销毁后不执行；拷贝/写文件取消保留旧目标；Preferences 已提交写入保留，SQLite 提交前取消回滚且共享连接仍可用。 | Host: CapIOExecutorTests/testDestroySkipsQueuedWorkAndTerminatesInFlightOnce（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapIOExecutorTests/testCancelledPartCopyAndWritePreserveExistingTarget（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapIOExecutorTests/testCancelledPreferencesWritesPreserveOldValueAndCommittedWrite（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapHTTPDatabaseTests/testSQLiteCancellationBeforeCommitRollsBackWithoutClosingSharedConnection（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 不承诺所有系统 provider 已发出的外部不可逆修改能被撤销。 |
| CAP-IO-05 | BLOCKED | Host owner 切换/排队取消子契约已通过；真实系统后台挂起、恢复后继续在途任务没有设备执行环境，整项 BLOCKED。 | Host: CapOwnerRuntimeTests/testGenerationReplacementKeepsEventsAndRequestsSeparate（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapOwnerRuntimeTests/testQueuedBackgroundResultIsCancelledBeforeMainDelivery（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 真实 iOS 挂起/恢复、后台资源限制、系统终止与在途 IO 联合行为未执行。 |
| CAP-IO-06 | PASS | Host 注入错误：损坏图无 JPEG 输出，非法输入/JSON/未知域或方法明确拒绝；HTTP 声明长度与分块溢出只产生一次终态，网络状态超时归还资源。 | Host: CapIOExecutorTests/testCorruptImageFileFailsWithoutJPEGOutput（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapIOExecutorTests/testBase64WriteLimitsAndInvalidDataFailWithoutTarget（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapOwnerRuntimeTests/testIllegalTransportRejectsWithoutDispatch（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapOwnerRuntimeTests/testActualDispatcherRejectsUnknownDomainAndMethod（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapHTTPDatabaseTests/testHTTPStreamStopsChunkedOverflowAndHasOneTerminal（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapOwnerRuntimeTests/testNetworkStatusCompletionReturnsTimeoutResource（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 真实 TLS/断网/系统传输错误及所有 provider 的错误组合未逐项执行。 |
| CAP-STATUS-01 | PASS | 真实目录/adapter Host：40 域、146 方法数与顺序保持；provider snapshot 决定实际方法状态；同步后台查询不解析 UIKit Host，也不宣称权限已授予。 | Host: CapHostStatusTests/testCatalogPreservesFortyDomainsAndOneHundredFortySixMethods（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapHostStatusTests/testProviderSnapshotControlsMethodStatusAndDoesNotClaimPermissions（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapHostStatusTests/testSyncStatusQueryDoesNotResolveUIKitHostFromBackground（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 目录一致不代表全部 146 方法在真实设备已实测。 |
| CAP-STATUS-02 | PASS | 真实 Cap adapter + 可控公开 Host：无 Host 的 StatusBar 只读 fallback 可用；安装 provider 后写调用由对应 adapter 消费；Orientation 等待 Host 并返回拒绝/取消。 | Host: CapHostStatusTests/testStatusBarFallbackReadAndInstalledHostWriteUseActualAdapter（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapHostStatusTests/testOrientationWaitsForHostAndReturnsRejectionInsteadOfSuccess（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapHostStatusTests/testDestroyedOwnerCancelsOrientationOnceAndDropsLateHostSuccess（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 真实 Scene 方向改变、分屏/多窗口以及 Shell 中性 System UI 全操作未逐项 UI 执行。 |
| CAP-STATUS-03 | BLOCKED | 配置缺失、blank 用途文案和 Host 拒绝的可控子契约已验证；相机/定位/通知等系统权限拒绝与受限状态未真实运行，整项 BLOCKED。 | Host: CapHostStatusTests/testMissingAndBlankUsageDescriptionFailBeforeSystemAdapter（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapHostStatusTests/testOrientationWaitsForHostAndReturnsRejectionInsteadOfSuccess（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapHostStatusTests/testCalendarUsageKeysFollowActualRequestAPIBySystemVersion（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 真实权限弹窗拒绝、系统受限状态、已拒绝后的重复调用未在物理设备执行。 |
| CAP-STATUS-04 | PASS | Simulator + Host availability：实际 Battery runtime 不能监控时明确 unknown/null，不虚报电量；可控租约驱动隔离硬件能力与 owner 管理。 | Host: CapOwnerRuntimeTests/testDeviceBatteryInfoReportsUnknownWhenRuntimeCannotMonitor（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapOwnerRuntimeTests/testBatteryMonitoringLeaseDriverRestoresOnlyAfterLastOwner（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 物理 Battery 用例跳过，真实可选硬件及更多系统 availability 分支未在 Device 执行。 |
| CAP-STATUS-05 | PASS | 真实 Module/Runtime transport：非法 JSON、未知域/方法在 dispatch 前或边界明确拒绝，终态不重复；不以空对象假成功。 | Host: CapOwnerRuntimeTests/testIllegalTransportRejectsWithoutDispatch（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapOwnerRuntimeTests/testActualDispatcherRejectsUnknownDomainAndMethod（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapOwnerRuntimeTests/testNaturalCompletionAndDuplicateCompletionHaveOneTerminal（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 不是全部 146 方法参数/业务服务错误与敏感信息通道的全面枚举。 |
| HOST-BASE-01 | PASS | Config + 本轮 Debug Build：11 项配置检查通过，两份实际隐私资源与源 dict 一致，Info XML 无重复键、用途文案非空，Podspec 资源与 iOS14 声明匹配。 | Config: 11 项源/实际 E2EHost.app 配置检查（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-config-check.json）；Build: LynxShellE2EHost build-for-testing 14（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-fourteenth-build.xcresult） | 本轮检查的是 map-free Debug E2EHost；Release 归档/审核与业务、第三方完整隐私用途不在该 PASS 内。 |
| HOST-BASE-02 | PASS | Host：缺失与空白用途文案在调用实际 system adapter 前返回配置失败；相机/音频/定位/日历按对应 API 选择正确用途键。 | Host: CapHostStatusTests/testMissingAndBlankUsageDescriptionFailBeforeSystemAdapter（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapHostStatusTests/testCameraAudioAndLocationUsageMappingMatchesActualMethods（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapHostStatusTests/testCalendarUsageKeysFollowActualRequestAPIBySystemVersion（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult） | 真实权限弹窗/系统受限状态另归 CAP-STATUS-03，未标记通过。 |
| HOST-BASE-03 | BLOCKED | 配置仍声明 iOS14；本地 Xcode Simulator 测试临时 deployment override15，并在 iOS18.1 运行。无 iOS14 runtime/真机，最低系统实跑 BLOCKED。 | Config: Podspec/project 最低系统声明与产物 MinimumOSVersion（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-config-check.json）；Build: 冻结 Lynx4.1 / PrimJS4.1.1 的 map-free 测试构建（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-fourteenth-build.xcresult） | iOS14 物理运行和最低系统所有 availability 分支未执行；不能用18.1通过替代。 |
| HOST-BASE-04 | PASS | 真实 SDK View + 多 owner Host/UI：公开 Module 注册可创建，宿主 onViewDestroy 按原 ctx 释放 Cap 恰好一次；多个 Module 与 Tab owner 保持隔离，Core 不反依赖 Cap。 | Host: ShellSDKDestroyIntegrationTests/testActualShellViewDestroyReleasesCapHostExactlyOnce（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult）；Host: CapOwnerRuntimeTests/testModuleRegistryCanCreateDestroyAndBroadcastAcrossThreads（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；Host: CapOwnerRuntimeTests/testExplicitContextDestroyKeepsOtherModuleAliveAndRejectsLateCreation（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-host-ui-tests.xcresult）；UI: NativeReadinessTemplateUITests/testRealTemplateTabsKeepInstancesAndUseDownloadedAsyncResources（/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult） | map-free E2E 证据不代表地图、全146方法、所有真实设备原生插件完整验收。 |

## 最新执行批次

PASS 限定为逐项列明的 Core/Host/UI 软件契约；missing 栏保留真实系统、硬件与更广业务子项，不推断 Device 通过。

| 环境 | 实际值 |
|---|---|
| 日期与时区 | 2026-10-04 / Asia/Shanghai |
| Xcode | 27.1（27A9269） |
| Core | Swift 6.4 / arm64e-apple-macos14.0 |
| Lynx / PrimJS | 4.1.0 / 4.1.1，冻结依赖 |
| Simulator | iPhone 16 Pro / iOS 18.1 |
| sourceMinimumIOS | 14.0 |
| testDeploymentOverride | 15.0 |
| Build SDK | iphonesimulator27.1 |
| physicalDevice | 本轮未运行 |
| OTA fixture | http://127.0.0.1:60543，隔离本地测试 Store，versioncode150 |

- Core 最终真实 Store/事务回归：PASS；total=99，passed=99，failed=0，skipped=0，suites=12。证据：/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log

```text
cd ios/OtaIOSSDK && swift test --no-parallel
```

- Host 有效方法结果（完整批次 + 最新重跑去重）：PASS；total=63，passed=62，failed=0，skipped=1。证据：/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-host-ui-effective-results.json

- UI 有效方法结果（完整批次 + 最新重跑去重）：PASS；total=5，passed=5，failed=0，skipped=0。证据：/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-host-ui-effective-results.json

- 最后针对性重跑（与上两行部分重叠，不能累加）：PASS；total=10，passed=10，failed=0，skipped=0。证据：/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult

- 最终 map-free E2E build-for-testing 14：PASS；。证据：/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-fourteenth-build.xcresult

```text
XcodeBuildMCP.build_sim（build-for-testing；LynxShellE2EHost；iPhone16Pro/iOS18.1）
```

- 当前实际宿主资源/配置核对：PASS；total=11，passed=11，failed=0，skipped=0。证据：/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-config-check.json

```text
python3 scripts/native-readiness/verify-ios-resources.py
```

- 最终真实模板 Lynx OTA 产物构建：PASS；。证据：/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/template-final-build.log

```text
pnpm --filter @cclx/lynx-template build:lynx:ota
```

## 配置与产物

配置检查：PASS。详情见 results/ios-config-check.json。

最低系统运行：BLOCKED；本机无 iOS 14 runtime／真机；配置和新系统构建不能替代最低系统运行验证。

模板使用 HomePage / OtaEcommercePage + Async 3；地址 http://127.0.0.1:60543。v1/v2 仅发布元数据变化，字节相同，不能当成业务代码升级内容证明。

## 历史失败与复跑

- 启动 TRIAL 回归先失败：旧 selected 启动路径没有统一清除遗留 TRIAL；新增针对性用例捕获原行为。 处理：首次读取前统一启动维护；保留 PENDING，直接 SDK beginTrial 先完成维护，重复维护不清活跃 trial。 复跑：/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-core-final.log

- 第一次 Host 电池断言失败：Simulator 无真实 Battery monitoring，初次断言误以为系统会变为监控开启。 处理：区分 owner 租约协议驱动与物理电池能力；Simulator 返回 unknown，物理用例 XCTSkip 保留。 复跑：/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-host-ui-effective-results.json

- 实际 SDK clear/destroy 集成失败：Lynx 4.1 Darwin Destroy 为空，clearForDestroy 不自动调用 Swift Cap Module 的 destroy。 处理：Shell 公开中性 onViewDestroy 入口；Host composition root 将原 ctx 精确交给 Cap teardown。真实 View 销毁用例验证一次释放。 复跑：/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult

- 第一次真实模板 Tab UI 断言失败：把整个 Tab debug 字符串比较为首页实例；新加载 settings 段的合法变化误触发失败。 处理：只比较首页的实例段，同时保留 latest/main 下载计数不变的实际断言。 复跑：/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult

- 完整 68 项批次：66 PASS / 1 FAIL / 1 SKIP：MissingPage 用例 XCTAssertNil 对合法 embedded State 指针作了错误假定；非业务包损坏，原始失败完整保留。 处理：登记真实 App baseline 后分别捕获 State current 指针与 App 资源 releaseId；MissingPage 后与各自 before 比较，并确认 candidate 为 pending。 复跑：/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-template-retest.xcresult

## 本轮实施要点

- 候选健康门禁沿用已有 candidateActivationEnabled。测试显式开启；正式 Host 按现有配置接线，不新增开关或协议版本门槛。
- 模板 AppRoot 消费 useGlobalPropsChanged；Host 安全区统一为 CSS px；真实 Lynx inline CSS variables 已开启。Home/Shop/Lazy 只消费一次安全距离；Web 缺 Host 时保留 env() 行为。
- 使用用户模板 Home/Ecommerce 与 Async3，通过本地 HTTP 下载真实字节。v1/v2 仅发布元数据不同，字节相同，不能称为业务代码内容升级。
- Core 不依赖 Cap。Host 注册 onViewDestroy 并按原 ctx teardown；公开 provider 与 Shell 中性 System UI API 负责源 View 归属。
- 代码回退不自动逆迁移业务数据。业务持久化/schema 需要兼容可回退版本，或将不可逆写入延后到健康确认。
- Root 已实际查看干净首页截图：系统时钟与自绘 header 不再覆盖。截图仅为 portrait；横屏、真机 FPS 和所有窗口变化未由该图验证。

## 跨阶段门禁

- 跨阶段全仓静态门禁：待 Android 对齐：原始结果 111 PASS / 2 FAIL。两项原始 FAIL 均为 Android 尚未新增 markOtaHealthy 与跨端 ABI 一致性；不是 iOS 现存运行失败。Android 完成后必须重跑并清除全仓门禁失败。 日志：/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-static-gate-after-contract.log

## 源码与产物指纹

原生 HEAD：39cba0d4d0c0be036ceea5b72429cfe7f84018aa。模板 HEAD：bed70027c89ae77ddf0e53ce9e1e010e12f099b4。

两个工作树均含本轮未提交修改；没有commit/push；保留原Harmony dirty baseline。

| 模板产物 | size | SHA-256 |
|---|---|---|
| /Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxAppPackagesAndTemplates/templates/lynx-template/dist/test/10020000/HomePage.lynx.bundle | 140369 | sha256:4f68268d7e7b620220019c2ffb8fcc42273c7087701c84775aee7a7a1b538b77 |
| /Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxAppPackagesAndTemplates/templates/lynx-template/dist/test/10020000/OtaEcommercePage.lynx.bundle | 287726 | sha256:762d7bbaab7c61010c880cb78c2c5eaa9154b59e5c97af45e4a88f764ad96240 |
| /Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxAppPackagesAndTemplates/templates/lynx-template/dist/test/10020000/lazy-bundle/src_components_store_CampaignPage.tsx.f3ebe136b85b1168.bundle | 169152 | sha256:32efd243d43641c2474066bb8b387f7c1c7e08eb1fed7055e2c5edec5f6881b2 |
| /Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxAppPackagesAndTemplates/templates/lynx-template/dist/test/10020000/lazy-bundle/src_components_store_ProductDetailPage.tsx.f3ebe136b85b1168.bundle | 21485 | sha256:08e1e04986296f6d4c976d69f2d437b47c42e80f7907467a542b19f7c1bf95e4 |
| /Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxAppPackagesAndTemplates/templates/lynx-template/dist/test/10020000/lazy-bundle/src_components_store_ReviewsPage.tsx.f3ebe136b85b1168.bundle | 20126 | sha256:4e760b36b44f69e10e5aa346eb6d9fe8cdcf826b6ba7cb9fedab36637a4969f0 |

| 原生生产文件 | SHA-256 |
|---|---|
| ios/LynxShellKit/Bridge/LynxShellModule.swift | 3c5d92566dc7066b8dbf6fd03f2938893af431888c8e28fc61f095ce607b143a |
| ios/LynxShellKit/Bridge/ShellMediaBridge.swift | f54e1cf9af4b829009dc92d76d4e5abee2f30c7492db31fa7b318d509d7557e5 |
| ios/LynxShellKit/Container/LynxContainerViewController.swift | cc4c0e291d75c5f00e3e0183423b5e4af65e8f1e0a2f0518f12ee3914b7f8677 |
| ios/LynxShellKit/Container/LynxTabLoadGeneration.swift | e06fd37321e73a7f9c995f08985d09082579862bdb2a83a89fbdd4be50ffff28 |
| ios/LynxShellKit/Diagnostics/LynxDebugBridge.swift | 9f63f7b409c590361fc71cc75cbbcc413c28201797d1dd030795ccf0a1722048 |
| ios/LynxShellKit/LynxRouter.swift | 7fee658daf1b1ca8387b3e94ee10b08929266bd14be2bb1bd088a06800f49e2b |
| ios/LynxShellKit/LynxShell.swift | ea73b4421aa41a2f6ca1628154ea1c6648d41ed6f258916114d6d653b8306770 |
| ios/LynxShellKit/Model/LynxPageRequest.swift | f505b5c7e13e9a58a1378e23ca4bcaa4e948a2b96ba9ccea39d18472957a66a1 |
| ios/LynxShellKit/Model/ShellTransitionSpec.swift | e4be40cc0bb39635913f1c19e4771c8f2facab562010f08b61832afe698aba16 |
| ios/LynxShellKit/Monitoring/LynxMonitor.swift | b78866fbedc4b49c546facb8c6abf256a86cbb8ae6e03ae48fd73a0b53296fe1 |
| ios/LynxShellKit/Monitoring/LynxMonitorDiagnosticProvider.swift | 6fd1c8efd4c6c3bb2d3ffd860fc7e6e6a8619372c48736cfc0684ad88c082863 |
| ios/LynxShellKit/Monitoring/LynxMonitorModels.swift | eb596c1ebbee7fe6c722976a85e27ef8fa22a063dbaedb67d2b82a08eb3d71cd |
| ios/LynxShellKit/Monitoring/LynxMonitorObserver.swift | 7c2fe2ed5d9f8dc011d343b6431f42ab3a84349042875156050f876aa63b0852 |
| ios/LynxShellKit/Monitoring/LynxMonitorSanitizer.swift | fe81735fee8590c2226a9e56445ff477d9a5198dd7582c0a0f1c990b7087e3a2 |
| ios/LynxShellKit/Monitoring/LynxMonitorScope.swift | 1c5b2f4ac14541cb20c6eb9c275e8ae271cf05fffd3dde8aa3497d41682e3693 |
| ios/LynxShellKit/Native/LynxNativeRuntime.h | b7e675f1505e7124da6342fd6c9dd2ac7fa7ef70f5a01b70e62528f96dc5f1f6 |
| ios/LynxShellKit/Native/LynxNativeRuntime.m | 8141193a8294b1c83aea3fbcd74d66999b12c1c534184ac5dd8bae93bcf01723 |
| ios/LynxShellKit/OTA/LynxOtaRuntime.swift | ec739786ed8a0faf9bcaf1931fa37d4408b7ca3eea89615a2e855a241a08f016 |
| ios/LynxShellKit/OTA/LynxSDKVersionResolver.swift | 63c00784eabb50ef08fd23baf7f1d0ad39f20e9c2b62347d1e78310fdf691bd9 |
| ios/LynxShellKit/Resource/ShellPreparedRouteStore.swift | d13ca1013baace01b202fdbe01e660085e68531a76d702374ef1bf8837a149e9 |
| ios/LynxShellKit/Resource/ShellSidecarResources.swift | 44a5841ca6e75b69bfa90e8250dc644d45e33fd331fee6c39b5b9b94125b2178 |
| ios/LynxShellKit/Resource/ShellTemplateProvider.swift | 18698a30a50118dab6999db1f2fa5c56250035ce728f840eb7322bf4e6116a2a |
| ios/LynxShellKit/Resources/PrivacyInfo.xcprivacy | 2394760e94f3a28fb3ee1e206339e3127b182215ad598be85bf65a0fae7bce2d |
| ios/LynxShellKit/Routing/LynxRouteParser.swift | 5c04c1e7836e524554c37787ba1609a1d0976e262a6553c08a64eff7ef4bf7b7 |
| ios/LynxShellKit/Routing/ShellNavigator.swift | d0cd6c32d9125d4e9601b50ce5a7e4e856666ff74889541ca4113908decb15e4 |
| ios/LynxShellKit/Runtime/LynxOtaHealthGate.swift | 52dfcdd95a0cc523c604bdcca5483a067e50c7fa575faf761756ec32bdcfb9e3 |
| ios/LynxShellKit/Runtime/LynxSystemUIHandle.swift | fac335e3b50df65c0569e018add60311d3efb0e120204a61f64d56454e7f2183 |
| ios/LynxShellKit/Runtime/ShellGlobalPropsFactory.swift | 19c53e5bda1b4ddef4531c620934263412a7f63f0f5aba59f7d94a5d4af88d44 |
| ios/LynxShellKit/Runtime/ShellLayoutSnapshot.swift | f3dfe3a9b99e92b3fcffdcb98be6b092faa051dc57563475089dbbe7a066d527 |
| ios/LynxShellKit/Runtime/ShellLocaleStore.swift | 35ea06e0ea0fe8cd8e4d109bcd282ee30877972a5082938217aa2c6051bb24b2 |
| ios/LynxShellKit/Runtime/ShellMessageHub.swift | fecae2570e216155c07c70e447ab13b5eb2194e036ee96cdb800c24d856ea934 |
| ios/LynxShellKit/Transition/LynxFirstScreenObserver.swift | 42c1842b2e4ae948e548e81b75b69416d4b852311af2ecaf6e5c21689ea59846 |
| ios/LynxShellKit/Transition/ShellBottomSheetMotion.swift | 70071c72d6581f989c3d58e4c2ae8745662f46e48a8b8994bccac531ff90ef43 |
| ios/LynxShellKit/Transition/ShellHeroSheetMotion.swift | 4a51f45795d4365a65f43ff80e3dd8fbe0d59a820da1547f82e73e6c6509d23e |
| ios/LynxShellKit/Transition/ShellNavigationAnimator.swift | f20ba9f89695cbd2fa9b6e9624f15f648cef242f65d829eaa64f2dfff81cf7dc |
| ios/LynxShellKit/Transition/ShellTransitionCoordinator.swift | b377779c3da1dac2aa7aac7a759bc576d7b75266c75178da07b7299f49ccea2b |
| ios/LynxShellKit/UI/ShellErrorView.swift | 933324bcc00aa350b2e1b828af63ec0090c2301af86b9b17c8fdd7ae08bb30be |
| ios/LynxShellKit/UI/ShellLoadingView.swift | c2288b4df47feb7d98cc11ee124b95d0f4d0407e8aa31f01a4097ca234389e5c |
| ios/LynxShellKit/UI/UIColor+ShellHex.swift | 831e00461f7f34ce87abeebc1383152f68c880377437ae6aac81cd0acbb4da7c |
| ios/LynxCapacitorKit/Bridge/LynxCapabilitySemantics.swift | cc997f91630d73efb229f8301ca6d26f822ce814bb1fd585bfafe1cfd552f530 |
| ios/LynxCapacitorKit/Bridge/LynxCapacitorHostProvider.swift | 54d3774cc64e00907e5771750cc95c1d06e6bd4a7411719dad40f3193e168db2 |
| ios/LynxCapacitorKit/Bridge/LynxCapacitorModule.swift | 6bc2fc7411de96d21acc8631f440f53d22a62728966780013b55ffcf4195b408 |
| ios/LynxCapacitorKit/Bridge/LynxNativeCapabilityCatalog.swift | 1279b2de91a7a2c83075fccecda4804eada6c80ff93cdbd3385e40e971630da9 |
| ios/LynxCapacitorKit/Bridge/LynxNativeCapabilityContract.swift | 8b6c0408e93485ce8568e826f0905540a8f46be32f8b5255374b6cf075583909 |
| ios/LynxCapacitorKit/Bridge/LynxNativeCapabilityDispatcher.swift | cf76150cb77d6d87c487a21a9a1562200e7467d4ee25f1a03d6f841dede68b52 |
| ios/LynxCapacitorKit/Bridge/LynxNativeCapabilityRuntime.swift | c64abcf0b14cf39f211ff36aded0808072acb209668ce532d0817f99c1be9df6 |
| ios/LynxCapacitorKit/Bridge/LynxNativeIOExecutor.swift | f38c2b3ee23e10d1e449cf9260ec6272789f4e613b5ddf7cc803acce3292cf30 |
| ios/LynxCapacitorKit/Bridge/LynxNativeOwnerScope.swift | 7a44dcfcfe49f93e288cca54f05ca7723d11a3d9bd492b3a460e4276085e9dbc |
| ios/LynxCapacitorKit/Capabilities/LynxNativeAudioCapabilities.swift | 751033e9512f00a397dc5dd73aa2c31a217e51c45d96c3775eb26091e9fccee0 |
| ios/LynxCapacitorKit/Capabilities/LynxNativeBarcodeCapabilities.swift | 6268f55db0494d4de99b693c54749ecfe3f243a397af4fa1a14615ce62b1455b |
| ios/LynxCapacitorKit/Capabilities/LynxNativeBiometricsCapabilities.swift | a016f095c90fc0466130b9e643735e5971988b39860d75064d61995e4875f4ca |
| ios/LynxCapacitorKit/Capabilities/LynxNativeDatabaseCapabilities.swift | 802e566067c26686146ed2353eb679b376a3ac6e097a84ab6f3ea0d0529c85fa |
| ios/LynxCapacitorKit/Capabilities/LynxNativeHTTPStream.swift | 8c6ab5484d5fdbabb154e04682351454639d8af434d51f4c62327673345f6162 |
| ios/LynxCapacitorKit/Capabilities/LynxNativeInteractiveCapabilities.swift | 68700160a60f833825fb55af92f0d695db3b0bea603e987d3557c2de49d2939b |
| ios/LynxCapacitorKit/Capabilities/LynxNativeKeepAwakeLeases.swift | cd3fddb556e01b317ce40c0df0546d5c05351bb221d5e68b914d20883c5f50c6 |
| ios/LynxCapacitorKit/Capabilities/LynxNativeMediaCapabilities.swift | 0e3cfae641628c9fadcf8fb4c41b2d208fae1ddf0ec03cdef7c5250b34f53983 |
| ios/LynxCapacitorKit/Capabilities/LynxNativeProviderCapabilities.swift | 6c2e9feb4c64348a1563ea7be988ca0beef351a198f57c7989627fdf98747fbe |
| ios/LynxCapacitorKit/Capabilities/LynxNativeSystemCapabilities.swift | 02e01a3698dfa9947c0b22ba60b4a313791c72aef871fbb7a76f3f6bb4353bf0 |
| ios/LynxCapacitorKit/Resources/PrivacyInfo.xcprivacy | a331d51864743ebe4e00dd22360b4a538b6b3ac26a6b3eb54094e60a36959a12 |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/BundleRuntime.swift | e1d6abfe24bb4df8d381456692f8a060dee58fce962c90859fccd91f236effe9 |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/CanonicalOtaStore.swift | bbfa600536b3411e145898cf7b6a84fb02db1eac73f4aa5b9833442b78f0e159 |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/ContentAddressedOtaStore.swift | 85639c5aece0957df0fa08e813fe7e7657f6a50abbfc1058772e49f614e7906c |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/LynxHotUpdate.swift | 451cc9b236053ec546053e03ed2b4d8c2dab5331b4fbb117475b04475265118a |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/Models.swift | 42f3d62b7bb3a34e05e5f2de64faa2c6abf1c92eb58e38d0648f0edee7fba068 |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/OtaAsyncBundleStore.swift | 7783846f464f05acfa52953ace8de2bb51a3502df64da3da3731d1c71e9c8de0 |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/OtaBundleLease.swift | 3dbb2377b6fbea5d64a404bceb9af78c434d0f584782e7fcbfb2948801e9fe16 |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/OtaHTTP.swift | cb9bb737bbc56d897c9d8e6d8feab674fcfe852072112d2ed079ab45625d0c7d |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/OtaReleaseStoreBackend.swift | d1b1195d400c0846e913466f22a2e8493d34cf953267b6cfd84ff09da1fce3ff |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/OtaSDK.swift | d158795fa998260d2a6bda380b26589cddf0ffa1543d54fe4b26e2f62f27619e |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/OtaSDKError.swift | 91e05e1fe4044fc507bea4eafef623cc4e1adb0f06337d59cfa3b33142d81974 |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/OtaSelection.swift | 5b5d3f4c37bebe8aa492f0e65f0ba1f96145810396a346bf8e3d836579be6108 |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/OtaSidecarDisk.swift | 7946f6d465d40ae52183a59211c172b803056650f4603c4b7da4f99c4e4c2bf7 |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/OtaSidecarModels.swift | f0315ae9d60317645db6f6630ad2b9d8ef9f894d628834f5b48c1b59e01a121a |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/OtaSidecarRetention.swift | 19f89d72f1a68d6f53c5c8afd2ba190726d4b57f810b42368b18bfd7aaa73031 |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/OtaStorageDiagnostics.swift | 3dbbb153fe0a797ef64e34ded0fdd58cd2160d4b2caa24343bc7ed9df4c415d4 |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/OtaStore.swift | 11326d168ff611893b3c92eec9246275d59691fb422cab98ad8eea99449cd3c6 |
| ios/OtaIOSSDK/Sources/OtaIOSSDK/ReleaseTransaction.swift | f1c293900b7ded35eb3a21edcca8e86051e3e7e48bab566913a4bd21e571e99d |
| ios/LynxShellSample/App/AppDelegate.swift | 212d6ae58a0c441e7acec39655eb62f601eeedf6d61201616fc57555895fe9eb |
| ios/LynxShellSample/App/LynxCapacitorSampleHost.swift | 39fb32a33edb5e46ccdce9f529a91dc2a43c851004d553e2456c0afffdd0de7a |
| ios/LynxShellSample/App/SceneDelegate.swift | f76f75e5fed289ea1cb2887f108114cbb2119b5b1b9123edab071e2a3ded76c9 |

## 本轮截图

![真实模板首页：隐藏诊断覆盖层后核对顶部安全区域](/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-screenshots/4EC5002E-CBEC-4E28-8C5A-25682B8A6D68.png)

真实模板首页：隐藏诊断覆盖层后核对顶部安全区域

![TRIAL 进程终止后：OTA 503 重启恢复 v1 稳定页面](/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-screenshots/DD649F45-5138-4B5F-8739-7A9EC4697CC5.png)

TRIAL 进程终止后：OTA 503 重启恢复 v1 稳定页面

![真实模板 v2 元数据 TRIAL：终止进程前](/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-screenshots/4542B070-F27C-438B-91A2-9CBD628242B9.png)

真实模板 v2 元数据 TRIAL：终止进程前

![本地 OTA 503 时重启读取稳定首页](/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-screenshots/9C610345-FCF7-4587-98E3-6050689881CA.png)

本地 OTA 503 时重启读取稳定首页

![真实模板首页：下载后完成首屏与业务健康确认](/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-screenshots/106BDD9E-950F-4D11-9E05-E56870A475E4.png)

真实模板首页：下载后完成首屏与业务健康确认

![真实模板 Tab：多次切换复用原首页实例](/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-screenshots/7D4F1B12-E089-47D8-B6C5-529E1E476B06.png)

真实模板 Tab：多次切换复用原首页实例

![真实模板 Async 商品详情：安全区域与自绘导航](/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-screenshots/EE5C930D-913C-4687-89F3-FCE84A59B6BF.png)

真实模板 Async 商品详情：安全区域与自绘导航

![真实模板电商页：宿主安全区域在页面中只加一次](/Users/nieyutan/.codex/worktrees/android-ios-navigation-safe-area/lynx-navigation-to-ota/.workflow/lynx-native-readiness-ios-android/results/ios-final-screenshots/AA5A85FB-EAC2-4865-A470-8400BAAED2E7.png)

真实模板电商页：宿主安全区域在页面中只加一次

## 未覆盖范围

- CAP-IO-05：真实系统后台挂起/恢复未执行。CAP-STATUS-03：实际系统权限拒绝/受限未执行。HOST-BASE-03：iOS14 运行无环境。
- 本地软件门禁允许开始 Android；跨阶段全仓静态门禁仍有两项等待 Android 健康 API/ABI 对齐，不代表整个三端工程已完成。
- 所有 PASS 限定于每行列明的 Core/Host/UI 软件契约；硬件、真实系统 UI、真实网络与更广业务数据子项的缺口保留。
- 最终布局截图只覆盖 portrait；横屏、真机 FPS 与所有窗口尺寸变化没有本轮完整证据。
- iOS 14 实机/runtime 未运行；iOS 18.1 的模拟器证据不能替代。
- 相机、通知、定位、生物识别等真实硬件/权限、系统后台、低磁盘未因单测通过而被证明。
- 本轮没有整体 FPS、峰值内存、长时间泄漏或所有 146 个能力方法的完整实测结论。
- iOS 14 实际运行；真机硬件/权限、系统后台、低磁盘。
- 完整 146 方法、整体 FPS、峰值内存与长期泄漏不由本轮单测推断。

当前没有 commit、push 或正式发布。
