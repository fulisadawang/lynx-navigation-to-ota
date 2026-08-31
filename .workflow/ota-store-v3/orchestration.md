# Orchestration: OTA Store v3 三端真正增量更新与运行态验收

## Execution Rules

- Keep the original objective intact.
- Ask for approval before risky, expensive, external, or destructive actions.
- Keep immediate blocking work local.
- Delegate only bounded, disjoint, materially useful packets.
- Integrate packet results before final verification.

## Branching Rules

- 当前工作分支若存在用户改动，先记录状态，不做 reset/checkout 覆盖。
- 如需隔离实现，主线程可以创建 `codex/ota-store-v3` 或平台子分支，但不强制改写当前 PR。
- iOS、Android、HarmonyOS 的实现与报告不能并行写同一文件；协议和 fixture 完成后按平台串行。
- 本轮没有 push/merge 授权；最终只保留本地 commit-ready 改动，除非用户另行要求。

## Packet Prompts

### P0 — 测试用例与协议冻结

目标：把 100→1、路由 Snapshot、CAS、GC、lease、回滚和故障边界写成可执行测试用例；冻结完整 Manifest、轻量 latest index、CAS Object、State v3 和统一指标。

验收：所有 Critical 用例有前置/动作/期望/证据；明确下载对象数、写入对象数、复制数、稳定占用和峰值；本地 Server 能提供 deterministic V1/V2。

### P1 — iOS

目标：在 iOS 实现 Store v3、CAS、NavigationSnapshot、UIViewController/Native Tab lease；用本地 OTA Server 和 Playground 100 Bundle 运行 V1→V2 只改 1 个；输出带截图 HTML 报告。

不得修改 Android/Harmony 实现。必须先通过 iOS 单测、构建、Simulator UI/路由/Tab/磁盘/故障证据，再解锁 P2。

### P2 — Android

目标：在 Android 实现与 iOS 同协议的 Store v3、CAS、Activity/Fragment Snapshot、lease、GC；跑同一 100→1 fixture；输出带截图 HTML 报告。

必须区分 JVM、instrumentation、adb/真机和本地 Server 证据；不把静态或 JVM 结果冒充 UI 通过。

### P3 — HarmonyOS

目标：在 HarmonyOS 实现 Store v3、CAS、ArkUI Page/Tabs Snapshot、lease、GC；无 candidate；跑同一 fixture；输出带截图 HTML 报告。

必须使用 DevEco 模拟器或真机，记录真实 SDK 对原子文件操作的能力；Mock Server 只替代外网服务，不替代平台运行态。

### P4 — 集成与最终验收

目标：比较三端指标和报告，核对协议/路径/路由/版本差异，补齐跨端缺口并生成最终 HTML/Markdown 汇总。

不得在 P4 引入新的架构方向；只能修复已证明的问题或标记未覆盖边界。

## Completion Audit

- `state.json` 中 P0～P4 状态与结果文件一致。
- 每个平台都有 source/build/runtime/report 四类证据。
- 100→1 指标满足硬门槛，且完整 Manifest 仍能随机打开所有 100 个 Bundle。
- 同一 session 版本不漂移，Tab 切换零网络，主动刷新后才切换。
- 任意事务故障后 current/previous/candidate/lease/GC 状态可恢复。
- 本地 Server、截图、报告和 fixture 不含凭证。
- 运行 `verify_workflow.py` 和 `collect_results.py`，最后报告明确真实服务/物理设备未覆盖项。
