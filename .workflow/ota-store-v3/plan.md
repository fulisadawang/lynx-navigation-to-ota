# OTA Store v3 三端真正增量更新与运行态验收

## Goal

在不依赖外网 OTA Server 的前提下，为 Android、iOS、HarmonyOS 建立并实现真正的 OTA Store v3：完整逻辑 Manifest、App ID 隔离的 SHA-256 CAS 对象库、原子 State、NavigationSnapshot/lease 和 Mark-and-Sweep GC。使用 Playground 生成 100 个 Bundle，构造 V1 全量与 V2 只变更 1 个 Bundle 的本地 OTA 场景，严格按 iOS → Android → HarmonyOS 顺序完成代码、构建、运行态、截图和 HTML 报告验收。

## Success Criteria

- 100→1 场景：V2 Manifest 仍包含 100 个 Bundle；二进制网络下载数为 1；新增对象写入数为 1；未变化对象复制数为 0。
- V1/V2 使用共享 CAS 对象，路由能够按 `bundlePath -> objectId` 完整解析；current/previous/candidate/lease 不会删除仍在使用的对象。
- 同一导航 session 内页面固定同一 Manifest 快照；Native Tab 普通切换零 OTA 网络请求，主动刷新完成后才创建新快照。
- 下载、对象提交、Manifest 写入、State 提交任意阶段进程终止后，冷启动只看到完整旧版本或完整新版本。
- 低磁盘、SHA/size 错误、网络中断、GC 与路由并发、delete、App ID 相同 SHA 隔离、V10→V5 均有自动化证据。
- iOS 先通过完整代码/本地 OTA/构建/模拟器运行态和带截图 HTML 报告；然后 Android 达到同样标准；最后 HarmonyOS 达到同样标准。任一端未通过不进入下一端。
- HarmonyOS 不创建 candidate/trial；Android/iOS 保留现有可选 candidate/trial 语义。

## Current Context

- 当前仓库：`/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota`。
- 已完成的 Store v2 作为行为基线；当前问题是未变化 Bundle 仍会复制到新 Release staging，路由没有 session 级版本快照。
- 当前代码和服务端合约把 `changedBundles` 作为目标 Release 的完整 Bundle 快照；v3 不引入增量 Manifest patch 链。
- OTA Server 外网不可依赖；本轮需要在仓库/临时本地服务中模拟完整 Manifest、错误、版本和回滚响应。
- Playground 需要生成 100 个可追踪 Bundle，并保留两个内容版本，只有 1 个 Bundle 在 V2 改变。

## Constraints

- 先做测试用例和 Golden Fixture，再实现代码。
- 严格按 iOS → Android → HarmonyOS 顺序；每端必须有截图和独立 HTML 报告。
- 完整 Manifest 是最终激活事实；Manifest 网络可用轻量 index + ETag，但不设计 patch 链。
- CAS 对象按 `apps/<appId>/objects/` 物理隔离，不跨 App ID 共享。
- embedded assets/App Bundle/rawfile 保持 no-copy；不复制到 OTA Store。
- Native Tab 普通切换不联网；主动刷新后才 reload；旧页面 lease 不被新版本替换。
- Demo 可以卸载重装切换 Store schema；不做旧 Store v2 迁移。
- 不记录或提交任何 token、cookie、签名 URL 或敏感服务端数据。
- 保留用户现有工作区改动；只修改本轮明确范围。

## Risks

- 三端文件 API 的原子 rename/fsync 能力不同，尤其 HarmonyOS 需要目标 SDK/设备确认。
- 本地模拟服务只能证明客户端协议和事务，不等价于真实生产 CDN/Server 可用性。
- iOS、Android 当前有 candidate，HarmonyOS 无 candidate，不能强行抹平差异。
- 路由快照如果传播不到新页面，可能出现同一 session 混用 V1/V2。
- GC 若错误计算 roots，会删除 active lease 或 staging 引用对象。
- Android/Harmony 运行态自动化能力弱于 iOS，需要明确不同证据层级。

## Approval Required

- 用户已明确授权多 Agent、长时间本地构建/模拟器测试、本地 OTA 服务和 Playground Bundle 生成。
- 如需 push、merge、真实外部 Server 写入或破坏性清理，另行确认；本轮不自动执行。

## Work Packets

- P0：跨端测试用例、Golden Fixture 和本地 OTA Server 契约（只读分析/设计）。
- P1：iOS Store v3、Router Snapshot、Tab、测试与截图 HTML（主线程写入，Agent review）。
- P2：Android Store v3、Router Snapshot、Fragment Tab、测试与截图 HTML（iOS 完成后）。
- P3：HarmonyOS Store v3、ArkUI Tab、测试与截图 HTML（Android 完成后）。
- P4：跨端故障/性能量化、报告汇总、静态/构建/运行态最终验收。

## Integration Policy

- P0 结果先合并为唯一协议，不允许平台自行发明字段语义。
- 平台实现严格串行：iOS → Android → HarmonyOS；平台间只共享协议和 fixture，不共享未完成代码。
- 每个平台完成后执行静态、单测、构建、本地 OTA 运行、截图和报告；通过后才解锁下一个 packet。
- 所有失败保留日志和报告中的 pending/failed 状态，禁止用 Mock/静态结果冒充真实平台证据。

## Verification

- 静态：跨端静态检查、协议/JSON schema、源代码 no-candidate 规则。
- 单测：对象去重、完整 Manifest、事务恢复、GC、lease、路由 generation、低磁盘。
- 本地服务：V1/V2、304、404、断网、错误 SHA/size、V10→V5。
- 运行态：iOS Simulator、Android emulator/device、HarmonyOS Pura 90 emulator/physical device，全部抓取截图和 UI/日志证据。
- 每端报告必须包含：版本身份、请求/写入计数、磁盘目录、路由/Tab 行为、失败恢复、截图、命令和未覆盖边界。
- 完成后运行 `verify_workflow.py`、`collect_results.py`、`git diff --check`；不自动 commit/push。

## Reusable Artifacts

- `.workflow/ota-store-v3/` 的协议、packet、结果和最终报告。
- `playground` 100 Bundle 生成 fixture 与本地 OTA Server 启动脚本。
- 三端统一 V1/V2 Manifest、对象计数、故障注入和 HTML 报告模板。
