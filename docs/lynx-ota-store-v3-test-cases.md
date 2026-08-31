# Lynx OTA Store v3 跨端完整测试用例

> 版本：v3 P0 · 日期：2026-08-30
> 范围：iOS → Android → HarmonyOS；本地 OTA Server；Playground 100 Bundle Golden Fixture。
> 核心目标：证明 V1 有 100 个 Bundle、V2 只有 1 个 Bundle 内容变化时，网络和磁盘都是真正增量，同时不破坏路由、Tab、回滚、GC 和故障恢复。

## 1. 验收结论规则

本测试文档把“增量”拆成四个独立指标：

```text
网络增量：只下载变化 Object
磁盘增量：只新增变化 Object，不复制未变化 Object
逻辑完整：V2 Manifest 仍然可以完整解析 100 个 Bundle
运行一致：同一导航 session 不混用不同 Release
```

以下任一项失败，Store v3 不能标记通过：

- V2 只下载了 1 个，但仍复制了 99 个未变化 Bundle；
- V2 Manifest 不是完整 100 条，或随机打开 Bundle 失败；
- State 指向缺失/损坏的 Manifest 或 Object；
- Native Tab 切换触发 OTA 网络或消费 candidate；
- 页面持有 lease 时 GC/delete 删除对象；
- 任意故障后出现半个 Release、错误 current 或不可恢复 orphan；
- iOS 结果通过但 Android/Harmony 未分别完成自己的运行态证据；
- HTML 报告缺截图、磁盘快照、请求计数或版本身份。

## 2. 测试身份和环境

### 2.1 固定 Fixture

```text
fixtureId: ota-store-v3-golden-100-v1-v2
lynxAppId: 10000001
env: TEST
hostApp: capp
```

Bundle 路径固定为：

```text
pages/10000001/bundle-000.lynx.bundle
...
pages/10000001/bundle-099.lynx.bundle
```

V1 与 V2 必须满足：

```text
V1 bundleCount = 100
V2 bundleCount = 100
V1/V2 bundlePath 集合完全相同
只有 bundle-050 的 bytes、size、SHA-256、URL 发生变化
其余 99 个 Bundle 逐字节一致
```

Fixture 内容必须由确定性算法生成，不能包含当前时间、随机 UUID、绝对路径或构建机信息。三个平台使用相同的 Bundle bytes/SHA，只在 Manifest scope 中使用不同的 platform。

### 2.2 运行身份

每次测试生成不含凭证的 `sessionId`：

```text
ios-v3-golden-100-<runId>
android-v3-golden-100-<runId>
harmony-v3-golden-100-<runId>
```

每条 Server、SDK、Store、Router、截图和 HTML 证据都必须带同一个 sessionId。

### 2.3 设备顺序

```text
iOS Simulator / 真机（如可用）
        ↓ iOS 全部门禁通过
Android Emulator / 真机
        ↓ Android 全部门禁通过
HarmonyOS Emulator / 真机
```

本地 fixture server 可以替代外网 OTA Server，但不能替代平台运行态。模拟器通过不能自动替代真机证据。

## 3. 统一计数器

每次同步开始前清零，测试准备阶段的 Bundle 生成和 embedded 注册不计入同步窗口。

```text
manifestBundleCount
manifestWriteCount
stateCommitCount
latestRequestCount
manifestRequestCount
bundleRequestCount
downloadedBundleCount
downloadedBytes
casWriteCount
casWriteBytes
byteCopyCount
copiedBytes
objectCountBefore
objectCountAfter
objectStoreBytesBefore
objectStoreBytesAfter
totalStoreBytesBefore
totalStoreBytesAfter
gcDeletedObjectCount
gcDeletedManifestCount
activeLeaseCount
routeResolvedReleaseId
routeSnapshotId
source
loadPolicy
```

### 3.1 预期计数

| 场景 | Manifest 条目 | 二进制下载 | CAS 写入 | 未变化复制 | State commit | 预期 current |
|---|---:|---:|---:|---:|---:|---|
| 空 Store 安装 V1 | 100 | 100 | 100 | 0 | 1 | V1 |
| V1 → V2，只变 050 | 100 | 1 | 1 | 0 | 1 | V2 |
| V2 重复检查，304 | 100 | 0 | 0 | 0 | 0 | 不变 |
| V2 candidate pending | 100 | 1 | 1 | 0 | 1（candidate） | V1 |
| candidate healthy | 100 | 0 | 0 | 0 | 1 | V2 |
| candidate discard | 100 | 0 | 0 | 0 | 1（discard） | V1 |
| latest 404 | 0 | 0 | 0 | 0 | 0 | 不变 |
| Manifest 404 | 未完成 | 0 | 0 | 0 | 0 | 不变 |
| 错误 SHA/size | 100 | 失败项 | 0 | 0 | 0 | 不变 |

### 3.2 100→1 必过断言

```text
V2.manifestBundleCount == 100
V2.bundlePathSet == V1.bundlePathSet
V2.changedBundlePathCount == 1
V2.downloadedBundleCount == 1
V2.casWriteCount == 1
V2.byteCopyCount == 0
V2.objectCountAfter == V1.objectCountBefore + 1
V2.randomRouteResolveSuccess == 100/100
```

如果实现暂时不能记录 `byteCopyCount`，不能用 `downloadedBundleCount=1` 代替磁盘增量通过；必须通过对象目录前后快照证明没有复制 99 个对象。

## 4. 本地 OTA Server 用例

### T01 — Fixture 生成正确

- 层级：脚本/离线校验；优先级：P0。
- 前置：无。
- 动作：生成 V1/V2 fixture，读取所有 Bundle 和 Manifest。
- 期望：两个版本各 100 个 Bundle；只有 050 SHA 不同；所有 size/SHA 可重算匹配。
- 证据：fixture manifest digest、文件数、文件 SHA、差异清单。

### T02 — Server 返回完整 V1/V2 Manifest

- 层级：本地 Server；优先级：P0。
- 动作：分别激活 V1、V2，请求 latest 和 release manifest。
- 期望：latest index 指向正确 release；完整 Manifest 返回 100 条；不存在 patch parent/operations 依赖。
- 证据：请求日志、HTTP 状态、Manifest 条数和 canonical digest。

### T03 — latest ETag/304

- 前置：客户端已持久化 V2 Manifest。
- 动作：带 V2 ETag 请求 latest，再带 Manifest ETag 请求 Manifest。
- 期望：latest 304 时客户端不再请求 Manifest；Manifest 304 时客户端使用已验证本地 Manifest；所有写入计数为 0。
- 证据：HTTP 304、ETag、前后 state/object/Manifest 快照。

### T04 — latest 404/空列表

- 前置：current=V1。
- 动作：Server 返回 latest 404 或全量空列表。
- 期望：current、previous、CAS Object 和 embedded 都不删除；页面仍可打开 V1。
- 证据：HTTP 响应、State、页面 source/releaseId。

### T05 — Manifest 404/不一致

- 前置：latest 指向 V2，但 Manifest 端点返回 404 或错误 digest。
- 动作：执行同步。
- 期望：不写 Object、不写 Manifest、不提交 State；current 保持 V1。
- 证据：请求计数、State、staging/transaction 清理结果。

### T06 — Bundle 404/断网/空响应

- 前置：V1 已稳定，V2 只有 050 变化。
- 动作：让 050 返回 404、连接中断或空 body。
- 期望：V2 不可见；V1 页面继续可读；已完成对象可作为 orphan 被后续 GC。
- 证据：下载日志、错误码、State、Object tree、重试结果。

### T07 — 错误 SHA/size/超限

- 动作：分别返回错误 SHA、错误 size、20 MiB 以上数据。
- 期望：对象不会 rename 到 CAS；Manifest/State 不提交。
- 证据：错误 reason code、CAS 前后快照、current。

### T08 — V10→V5

- 前置：客户端 current=V10；Server 准备完整 ACTIVE V5。
- 动作：latest 指向 V5，执行同步。
- 期望：客户端获取完整 V5 Manifest；本地已有 Object 复用，缺失 Object 才下载；最终 `current=V5, previous=V10`。
- 证据：Server response、对象下载数、State、V5 路由。

### T09 — ROLLED_BACK/DISABLED

- 动作：latest/Manifest 返回 `ROLLED_BACK` 或 `DISABLED`。
- 期望：目标不可激活，current 保持不变；不能隐式切 previous。
- 证据：State、错误/跳过 reason code、页面版本。

## 5. Store/CAS/事务用例

### T10 — 空 Store 安装 V1

- 层级：SDK/真实临时目录；优先级：P0。
- 期望：下载 100 个 Object、写入 100 个 Object、复制 0 个；Manifest 完整；State current=V1。
- 证据：对象文件数、每个 SHA、Manifest、State、计数器。

### T11 — V1→V2 只变 050

- 前置：T10 通过。
- 动作：激活 V2，执行同步。
- 期望：只请求 050；只新增一个 CAS Object；99 个旧 Object 文件身份不变；V2 Manifest 仍有 100 条；V1/V2 均可完整路由。
- 证据：请求日志、CAS inode/file identity、前后 Object tree、Manifest、State、100 次 route resolve。

### T12 — 相同 SHA 复用不复制

- 前置：V1 对象库存在 100 个对象。
- 动作：构造只修改 Manifest 元数据但不修改 bytes 的 V2。
- 期望：Object 下载数和写入数为 0；Manifest 可更新；不产生相同 SHA 的第二份物理对象。
- 证据：对象目录 hash/inode、写入计数和 Manifest digest。

### T13 — 重复同步幂等

- 动作：并发/连续触发两次 V2 同步。
- 期望：最终只有一个 V2 Manifest；Object 只写一次；State generation 单调；无重复 staging。
- 证据：transactionId、锁/队列日志、State generation、对象 count。

### T14 — 两个 App ID 相同 SHA/releaseId

- 前置：App A/B 使用相同 releaseId、bundlePath、SHA。
- 动作：分别安装、篡改 A、删除 A。
- 期望：A/B 物理对象和 State 独立；A 删除不影响 B；A 校验缓存不污染 B。
- 证据：两个 `apps/<appId>` 目录、删除后 B 路由结果。

### T15 — Manifest/State 原子提交

- 动作：在 Object durable、Manifest durable、State rename 前后注入 crash。
- 期望：重启后只能看到完整旧版本或完整新版本；不能看到 State 指向缺失 Manifest/Object。
- 证据：进程退出点、重启 State、Manifest、Object tree、route resolve。
- HarmonyOS 模拟器入口：使用 `aa start --ps lynx_ota_pause_point <point> --ps lynx_ota_pause_millis 15000 --ps lynx_ota_pause_token <unique>`，等待当前 token 的 HILOG 后由 HDC force-stop；保护性 `capacity_override=0` 启动读取中间 State，再正常冷启动重试。
- HarmonyOS 的 CAS Object 发布必须先 fsync 文件，再同步事务源目录和 CAS 目标目录；原子 Manifest/State 写入也必须同步父目录。State 提交前的有效 `transaction.json` 作为恢复索引保留到下一次成功提交，不能在新进程启动时无条件删除。

### T16 — `.part` 不可路由

- 动作：保留部分 `.part` 文件，尝试 resolve bundle。
- 期望：Router 不读取 `.part`；冷启动清理或保留为 transaction root，不能当 current。
- 证据：resolve 结果、文件名过滤、GC 日志。

### T17 — 中途 ENOSPC

- 动作：容量预检通过后，在 Object/Manifest/State 写入阶段分别注入 ENOSPC。
- 期望：旧 current 继续可读；半对象不进入 CAS；可以重试；错误包含 required/available/reclaimable。
- 证据：OS 错误、State、CAS、staging 和重试计数。
- HarmonyOS TEST-only 入口覆盖 enospc_object_publish、enospc_manifest_commit、
  enospc_state_commit 和 capacity_override=0；受控探针不等同真实 OS ENOSPC，报告必须分开标注。

### T18 — App 覆盖升级

- 动作：已有 remote V1 时覆盖安装新 App 包，embedded baseline 改变。
- 期望：合法 remote current 保留；embedded 不复制进 CAS；损坏 remote 可回新 embedded。
- 证据：升级前后 State/Object tree、embedded source、页面截图。

## 6. 路由和 Native Tab 用例

### T20 — 普通页面首次解析

- 前置：current=V1。
- 动作：打开 `bundle-000`。
- 期望：建立 NavigationSnapshot(V1) 和 lease；页面显示 appId/releaseId/source/bundlePath。
- 证据：页面截图、Snapshot、lease、Store snapshot。

### T21 — 同一 session 跳转不漂移

- 前置：Home V1 session 已创建。
- 动作：后台激活 V2，再从 Home 跳转 Detail。
- 期望：Detail 继承 V1 Snapshot，不读 V2；session 内 releaseId 始终 V1。
- 证据：Home/Detail 两张截图、route sessionId、releaseId 序列。

### T22 — 新 session 使用新 current

- 前置：V2 已 current。
- 动作：关闭旧 session，重新打开 root 页面。
- 期望：新 Snapshot 为 V2；旧 Snapshot lease 释放后可 GC V1 独有对象。
- 证据：新旧 Snapshot、lease count、GC 前后 Object tree。

### T23 — Native Tab 普通切换

- 前置：Tab group 绑定 V1 Snapshot。
- 动作：Home/Settings 往返 20 次。
- 期望：网络请求为 0；不调用 repair；不消费 candidate；实例和 Snapshot 不变。
- 证据：HTTP 计数、Tab instance identity、releaseId/source/loadPolicy 截图。

### T24 — Native Tab 主动刷新成功

- 前置：V1 current，Server 激活 V2。
- 动作：点击主动刷新，等待同步完成。
- 期望：先完成 V2 Object/Manifest/State，再创建新 Tab Snapshot 并 reload；不能同步未完成就销毁旧 Tab。
- 证据：事件时间线、旧/新 instance、State、截图。

### T25 — Native Tab 主动刷新失败

- 动作：让 V2 050 下载失败或 SHA 错误。
- 期望：旧 Tab 实例、V1 Snapshot、lease 和页面内容保持不变。
- 证据：错误提示截图、HTTP log、instance identity、State。

### T26 — 旧页面 lease 与新版本并存

- 前置：普通页面/Tab 仍使用 V1。
- 动作：激活 V2，执行 GC/delete。
- 期望：V1 Snapshot 页面仍能加载全部需要的 Bundle；V1 对象不被删除；lease 释放后才能 GC。
- 证据：页面实际读取、activeLeaseCount、GC 结果。

### T27 — 旧 generation 异步结果

- 动作：V1 prepare 尚未完成时触发 V2 refresh，再让 V1 结果晚到。
- 期望：旧 generation 不能覆盖 V2 页面，也不能复活旧 Tab instance。
- 证据：generation/session 日志、最终页面 releaseId。

### T28 — Direct HTTPS 隔离

- 动作：打开 Direct HTTPS Bundle。
- 期望：不进入 OTA Manifest/CAS/State，不参加 30 分钟门控；OTA session 不受影响。
- 证据：HTTP endpoint、Store snapshot、页面 source。

## 7. GC、删除、回滚和 Candidate 用例

### T30 — Mark-and-Sweep roots

- 前置：current=V2、previous=V1、candidate（Android/iOS）、live lease=V0、staging=V3。
- 动作：执行 GC。
- 期望：V0/V1/V2/V3 引用的 Manifest/Object 全部保留；其他 orphan 才删除。
- 证据：roots 列表、mark set、删除列表。

### T31 — Lease 关闭后 GC

- 动作：关闭 V0 lease，再执行 GC。
- 期望：仅 V0 不再被其他 root 引用的 Object/Manifest 被回收。
- 证据：lease count、GC deleted object、其他页面可读性。

### T32 — Delete 单个 App ID

- 动作：删除 App A，同时 App B 使用相同 SHA。
- 期望：A 的 State/candidate/Manifest/Objects 按 lease 规则清理；B 完全不受影响；embedded 不受影响。
- 证据：A/B 磁盘快照、页面 source、删除日志。

### T33 — Delete 全部 OTA

- 动作：删除全部 OTA，再打开 embedded 页面。
- 期望：有活体 lease 时先保护仍在使用的对象；进程退出后 purge root 清空远程对象，
  embedded rawfile/App Bundle 继续渲染；不生成 Bundle 备份目录。
- 证据：Object tree、页面截图、embedded source。

### T34 — Android/iOS Candidate pending/trial/healthy

- 动作：V1 current，V2 candidate pending；普通页面试用，Native Tab 同时切换。
- 期望：普通页面按策略试用 V2；current 仍 V1；Tab 永远 V1；healthy 后原子变为 V2/V1。
- 证据：State candidate、页面 source、Tab request count、promote 后 State。

### T35 — Candidate 首屏失败/discard

- 动作：V2 trial 首屏失败或进程在 trial 中终止。
- 期望：只 discard V2；V1 继续可读；V2 独有 Object 在 lease 关闭后 GC。
- 证据：candidate 状态、重启 State、GC、截图。

### T36 — Harmony 无 Candidate

- 动作：Harmony 激活 V2、首屏失败、重启、回滚。
- 期望：任何 State/目录/API 都没有 candidate/trial；只有 current/previous；失败按 previous/embedded 处理。
- 证据：源码扫描、State schema、磁盘目录、调用日志。

### T37 — 客户端直接 rollback

- 前置：current=V2、previous=V1。
- 动作：执行 rollback。
- 期望：State 原子交换到 V1；新 session 使用 V1；旧 session 仍由 Snapshot lease 保护。
- 证据：State generation、页面 releaseId、Manifest/Object 完整性。

### T38 — 服务端 V10→V5 与客户端 rollback 区分

- 动作：Server latest 指向 ACTIVE V5，再执行客户端 rollback。
- 期望：Server downgrade 是新目标安装；客户端 rollback 只使用本地 previous；二者 reason code 不混用。
- 证据：Server response、State、下载/复用计数、事件上报。

## 8. 三端平台运行态用例

### I01 — iOS 先行门禁

- Swift/SDK：完成 T01、T03、T05～T18、T30～T35。
- Simulator/UI：完成 T20～T28，至少截图：V1、V2、session pin、Tab cache-only、主动刷新、CAS 磁盘、故障恢复。
- 报告：`docs/ios-ota-store-v3-test-report.html`，无 P0 `FAIL/BLOCKED`。
- 通过后才进入 Android。

### A01 — Android 门禁

- JVM：使用同一 Golden Fixture，完成 T01、T03、T05～T18、T30～T35。
- Emulator/真机：完成 T20～T28；尽可能使用 instrumentation/UIAutomator，不能用 JVM 代替 UI。
- 报告：`docs/android-ota-store-v3-test-report.html`，单独记录 adb/logcat/磁盘快照。
- 通过后才进入 HarmonyOS。

### H01 — HarmonyOS 门禁

- ArkTS/Store harness：完成 T01、T03、T05～T18、T30～T33、T36～T38。
- DevEco Simulator/真机：完成 T20～T28；验证目标 SDK 的对象写入、rename、State replace 能力。
- 报告：`docs/harmony-ota-store-v3-test-report.html`，明确无 candidate。
- Mock Server 只替代外网，不替代 Harmony 平台运行态。

### X01 — 三端结果对齐

- 三端 V1/V2 Manifest 条目数均为 100。
- 三端 V2 二进制下载数均为 1。
- 三端 CAS 新 Object 写入数均为 1。
- 三端未变化 Object 复制数均为 0。
- 三端同一 session 不发生 releaseId 漂移。
- Android/iOS candidate 结果一致；Harmony candidate 维度明确为空。
- 三份 HTML 报告均包含截图、指标、磁盘快照、命令和未覆盖边界。

## 9. 崩溃和故障注入矩阵

| 故障点 | 旧 current | 新对象 | Manifest | State | 重启期望 |
|---|---|---|---|---|---|
| 下载中断 | 保持 | `.part` 删除/可识别 orphan | 无 | 不变 | V1 完整 |
| Object 写入中 | 保持 | 不可见半对象 | 无 | 不变 | V1 完整 |
| Object rename 后 | 保持 | 合法 orphan | 无 | 不变 | V1，后续 GC/复用 |
| Manifest 写入中 | 保持 | 可保留 | 不完整 | 不变 | V1 |
| Manifest durable 后 | 保持 | 完整 | orphan | 不变 | V1，GC Manifest |
| State commit 前 | 保持 | 完整 | 完整 | 旧 | V1 |
| State commit 后 | 新 | 完整 | 完整 | 新 | V2 |
| prune 前 | 新 | 新旧按 roots 保留 | 完整 | 新 | V2 |
| 中途 ENOSPC | 保持 | 不接收半对象 | 不提交 | 不变 | V1，可重试 |
| GC 中断 | 不变 | 已 mark 不删 | 不变 | 不变 | 可重跑 GC |

每个故障点都必须使用独立进程/force-stop 或等价机制验证；同进程抛异常只能作为补充证据。

HarmonyOS 本轮可直接复现：

    scripts/ota-store-v3/run-harmony-fault-tests.sh
    scripts/ota-store-v3/run-harmony-process-crash-tests.sh

两个脚本结束前都会执行 `scripts/ota-store-v3/assert-harmony-results.mjs`；任一
latest/Bundle/State/Manifest/CAS/恢复计数不符合预期，脚本在恢复 Server 控制面后以非零退出。

两个脚本只在本地 TEST Server 和指定 HDC 模拟器上运行；它们不会读取或写入生产凭证。

## 10. HTML 报告格式

每端独立报告至少包含：

```text
测试环境和设备
Git commit / fixture digest
Server 请求日志摘要
Manifest 100 条摘要
downloaded/casWrite/copy 计数
更新前后 Object/Manifest/State 磁盘树
route snapshot / releaseId / source / bundlePath
Tab cache-only 证据
lease/GC 证据
故障恢复证据
截图原图和截图说明
命令、exit code、日志摘要
PASS / FAIL / BLOCKED
未覆盖边界
```

Harmony 当前轮次的原始运行态数据：

```text
docs/assets/harmony-ota-store-v3/fault-test-results.jsonl
docs/assets/harmony-ota-store-v3/process-crash-results.jsonl
```

JSONL 机器断言命令：

```bash
node scripts/ota-store-v3/assert-harmony-results.mjs fault \
  docs/assets/harmony-ota-store-v3/fault-test-results.jsonl
node scripts/ota-store-v3/assert-harmony-results.mjs process-crash \
  docs/assets/harmony-ota-store-v3/process-crash-results.jsonl
```

报告中的 `PASS` 只允许由同层级实际证据支持：

- SDK PASS 不等于 UI PASS；
- 模拟器 PASS 不等于物理真机 PASS；
- 本地 Server PASS 不等于真实 OTA Server PASS；
- 静态检查 PASS 不等于崩溃恢复 PASS；
- 网络下载 1 个不等于磁盘增量 PASS。

## 11. 最终发布门禁

只有以下顺序全部完成，才允许 Store v3 标记生产候选：

```text
P0 测试用例/Fixture/本地 Server
  → iOS 代码 + 测试 + 构建 + 运行 + 截图 HTML
  → Android 代码 + 测试 + 构建 + 运行 + 截图 HTML
  → HarmonyOS 代码 + 测试 + 构建 + 运行 + 截图 HTML
  → 三端汇总与报告审计
```

任何平台的 P0 用例为 `FAIL` 或 `BLOCKED`，停止进入下一平台；报告必须如实保留未验证边界。
