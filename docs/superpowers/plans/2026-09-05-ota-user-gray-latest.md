# latest 三参数筛选与 Harmony 支持 Implementation Plan（修订 2）

> 2026-09-06 用户最新调整：Android 与 Harmony 不再要求模拟器测试。以下设备/截图条目对 iOS 已实际执行；后两端以完整代码、自动测试、构建与诚实标明未做设备验收的 HTML 交付，不继续启动模拟器。后两端原设备矩阵保留为可选后续测试计划，不再作为本轮完成门禁。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 本文为待执行计划，不授权自动部署、发布 npm 包、提交或合并 PR。

**Goal:** 优先完成工作区 Server 的 latest-bundle-list：增加 userId、versioncode、lynxSdkVersion 筛选和 platform=harmony；服务端验收后再修改三端 OTA 参数与用户注册方法。

**Architecture:** Server 统一选择器输出完整 Release 快照；Router 管理用户与在途请求代际，Store v3 用同一 CAS 库及带选择归属的原子 State 加载 Bundle。Native Tab 保留 cache-only，Android/iOS 保留可选 candidate，Harmony 不增加 candidate。

**Tech Stack:** Fastify、Zod、Prisma/MySQL、TypeScript contracts；Kotlin、Swift/UIKit、ArkTS；Store v3 SHA-256 CAS；现有本地 OTA fixture 与三端设备验收工具。

**Spec:** [完整技术设计](../../ota-user-gray-latest-design.md)，执行前必须阅读。所有接口名称、数据字段和选择顺序以该设计为准。

## Global Constraints

- 本次修改 `GET /api/ota/v1/releases/latest-bundle-list`，不创建 resolve-bundle-lists。
- 同一兼容 scope 内优先最高 releaseSequence，全量高于或等于灰度时选择全量；服务端显式回滚/embedded 指令优先。
- 序号在创建时分配且不变；规则修订独立递增，不比较 releaseId 字符串或 updatedAt。
- 新查询参数精确为 userId、versioncode、lynxSdkVersion，不把 versioncode 写成 appVersion/buildNumber，也不要求额外 selectionProtocol 参数。
- 新客户端总是提供 versioncode、lynxSdkVersion 和 platform；userId 可以匿名。全量包装与定向单条的成功形态保留，响应 selectionSchemaVersion 自描述。
- 当前用户信息仅由原生宿主注册，Lynx 页面 params 不可改写。
- 内置 bytes 不复制；CAS 不按用户复制；保持 App ID 物理隔离与 lease/transaction GC roots。
- 验证顺序：先 Server 及其 Contracts 前置，服务端 HTTP 和持久化测试通过后才开始 iOS → Android → Harmony。此之前不修改客户端业务代码。
- 本机 `harmony/lynx_shell_kit/BuildProfile.ets` 改动必须原样保留。
- 当前只新增方案文档。以下所有步骤未执行，不把前次静态 200 PASS 用作本方案验收。

## 仓库根与依赖

| 简称 | 绝对根目录 |
|---|---|
| Client | /Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota |
| Server | /Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxOtaServer |
| Contracts | /Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxContracts |

Server 当前消费已发布的 @cclx/lynx-ota-contracts ^0.1.1。实施时在独立测试 checkout 用已构建 tarball 验证新契约；真实集成须先按 Contracts 现有 Changesets 流程发布明确版本，再锁定 Server 依赖，不提交跨仓绝对路径。

## Task 1：Server 前置——版本约束、稳定排序与公共契约

**Files:**

- Modify（Contracts）：`packages/shared/src/index.ts`、`packages/shared/src/index.test.ts`，新增目标 package changeset。
- Modify（Server）：`prisma/schema.prisma`、`src/storage/contracts.ts`、`src/storage/prisma.ts`、`src/modules/release/repository.ts`、`src/bootstrap/db.ts`。
- Create（Server）：`prisma/migrations/20260905_ota_user_selection/migration.sql`、`scripts/backfill-release-sequences.mjs`、`src/modules/policy/selection-storage.test.ts`、`src/modules/policy/release-compatibility.ts`、`src/modules/policy/release-compatibility.test.ts`。

**Interfaces:** Consumes Spec 第 3、4、5、8 节；Produces VersionCodeRange、platformVersionCodeRanges、harmony 平台、LatestQueryContext、releaseSequence、policyRevision、SelectionMetadata、LatestSelectionResponse/LatestSingleResponse，以及 scope 内原子分配/修订能力。

- [ ] 先在共享包定义 Spec 的十进制字符串序号和响应 union；native decoder 不使用浮点精度；无效状态不伪造空 Bundle。
- [ ] 扩展 OtaPlatform 和发布平台枚举为 android/ios/harmony；修正 Prisma parseReleasePlatforms 只识别双端、未知值回落 Android 的分支。真实数据库创建 harmony Release 后回读仍必须是 harmony。
- [ ] 给 Release 新增公共 versionCodeRange 与按平台的 platformVersionCodeRanges，lynxSdkRange 复用现有字段。创建/详情/校验/发布/跨环境提升/存储都必须贯通范围，不只增加 GET 参数。
- [ ] 新增整数兼容 helper，验证上下界包含、正整数校验、大整数精度、平台独立范围。SDK 采用严格数字版本段比较，覆盖 4.10.0 > 4.9.0。
- [ ] 新查询中范围完全缺省表示无该限制；缺必要兼容上下文不放行。旧查询单独保留既有 SDK/版本名称校验分工，但排除带新增 versionCodeRange 的 Release。旧 minAppVersion 不自动转成 versionCodeRange，历史 Rule.buildNumberRange 不作为已实现条件。
- [ ] 写数据库隔离测试：同 scope 并发创建 20 个 Release，序号 20 个唯一且正数；不同 scope 可各自从 1 开始；状态编辑不得修改既有序号。
- [ ] migration 先增加 nullable 字段/计数器，再 dry-run 输出旧 Release 映射；校验唯一性后在专用测试数据库回填，最后加非空及唯一约束。
- [ ] 将控制状态、规则/Release 变更及修订增加纳入同一事务；注入中途异常，整个事务应回滚，读者不得见新状态配旧修订。
- [ ] 构建/类型/测试：Contracts 根执行 `pnpm typecheck && pnpm build && pnpm test`；Server 根执行 `pnpm typecheck`，数据库测试仅指向独立测试库。缺少测试库时记录未执行，禁止使用默认远程库。

测试应包含实际大整数，验证序列化不是 Number：

```ts
import assert from "node:assert/strict";
import test from "node:test";
test("release sequence survives JSON above Number precision", () => {
  const value = { releaseSequence: "9007199254740993" };
  const parsed = JSON.parse(JSON.stringify(value));
  assert.equal(parsed.releaseSequence, "9007199254740993");
  assert.ok(BigInt(parsed.releaseSequence) > 9007199254740992n);
});
```

兼容函数和边界测试（新增文件中实现，入参格式由 HTTP/发布 Schema 先行校验）：

```ts
export interface VersionCodeRange { min?: string; max?: string }
export function matchesVersionCode(
  versioncode: string | undefined, range?: VersionCodeRange,
): boolean {
  if (range?.min === undefined && range?.max === undefined) return true;
  if (versioncode === undefined) return false;
  const value = BigInt(versioncode);
  return (range.min === undefined || value >= BigInt(range.min)) &&
    (range.max === undefined || value <= BigInt(range.max));
}
```

```ts
import assert from "node:assert/strict";
import test from "node:test";
import { matchesVersionCode } from "./release-compatibility.js";
test("native versioncode range is inclusive", () => {
  const range = { min: "120", max: "199" };
  for (const [code, expected] of [
    ["119", false], ["120", true], ["199", true], ["200", false],
  ] as const) assert.equal(matchesVersionCode(code, range), expected);
  assert.equal(matchesVersionCode(undefined, range), false);
  assert.equal(matchesVersionCode("9007199254740993", {
    min: "9007199254740993", max: "9007199254740993",
  }), true);
});
```

## Task 2：唯一选择器与发布、灰度、回滚

**Files:**

- Create（Server）：`src/modules/policy/release-selector.ts`、`src/modules/policy/release-selector.test.ts`。
- Modify：`src/modules/policy/service.ts`、`src/modules/policy/matcher.ts`、`src/modules/release/service.ts`、`src/modules/rule/service.ts`、`src/modules/rollback/service.ts`、相关仓储。
- Test：`src/app.test.ts` 及新增选择器测试。

**Interfaces:** Consumes Task 1 序号与修订；Produces 共用选择器。先执行 override/兼容筛选，再调用纯排序函数。纯函数输入定义如下：

```ts
export interface EligibleRelease {
  releaseId: string;
  releaseSequence: string;
  kind: "full" | "gray";
}
export interface SelectionRule {
  ruleId: string;
  targetReleaseId: string;
  status: "ENABLED" | "DISABLED";
  priority: number;
  userWhitelist: readonly string[];
}
export interface SelectedRelease {
  release: EligibleRelease;
  ruleId?: string;
}
export function chooseLatestRelease(
  releases: readonly EligibleRelease[],
  rules: readonly SelectionRule[],
  userId?: string,
): SelectedRelease | undefined;
```

- [ ] 先写实际业务断言，确认“灰度优先直接 return”不能通过更高全量覆盖测试。

```ts
import assert from "node:assert/strict";
import test from "node:test";
import { chooseLatestRelease, type SelectionRule } from "./release-selector.js";
const rules: SelectionRule[] = [{
  ruleId: "demo-rule", targetReleaseId: "gray", status: "ENABLED",
  priority: 100, userWhitelist: ["user_demo_A"],
}];
test("full V7 wins over gray V6 for a whitelisted user", () => {
  const result = chooseLatestRelease([
    { releaseId: "full", releaseSequence: "7", kind: "full" },
    { releaseId: "gray", releaseSequence: "6", kind: "gray" },
  ], rules, "user_demo_A");
  assert.equal(result?.release.releaseId, "full");
});
test("gray V8 wins only for its audience", () => {
  const releases = [
    { releaseId: "full", releaseSequence: "7", kind: "full" as const },
    { releaseId: "gray", releaseSequence: "8", kind: "gray" as const },
  ];
  assert.equal(chooseLatestRelease(releases, rules, "user_demo_A")?.release.releaseId, "gray");
  assert.equal(chooseLatestRelease(releases, rules, "user_demo_B")?.release.releaseId, "full");
  assert.equal(chooseLatestRelease(releases, rules)?.release.releaseId, "full");
});
```

- [ ] 实现排序：先过滤 gray 的 ENABLED 匹配目标；按 BigInt sequence 降序，等序号 full 优先。同目标多规则按 priority/ruleId 确定诊断规则。
- [ ] service 先按 scope/ACTIVE 和 userId 建立可访问灰度目标集合，再过滤 versioncode/lynxSdkVersion，同时筛选 full 集合，然后比较最高 Release。不要只检查第一个灰度，失败后漏掉次高兼容灰度。旧 policy/match 保留 pageId/appVersion/协议额外限制，latest 不要求这些新 Query。
- [ ] 发布与规则校验必须发生在 ACTIVE 提交前，失败事务不留下半发布；统一使用 publishType 元数据，历史规则解除不改变发布类型。
- [ ] rollback/embedded 控制先于最高版本排序；兼容 V5 可被新修订显式选中；新 full 发布清除相应回滚锁定但不擅自关闭手动 embedded 开关。
- [ ] 执行 `pnpm test`，同时验证内存仓储与 Prisma 集成结果，不仅测试纯排序。

## Task 3：Server latest 三参数与 Harmony HTTP 验收

**Files:**

- Modify（Server）：`src/modules/release/schema.ts`、`src/modules/policy/controller.ts`、`src/modules/policy/schema.ts`、`src/modules/metrics/controller.ts`、`src/modules/alerts/service.ts`、`src/app.test.ts`、`package.json`、lockfile。
- Create（Server）：`src/modules/policy/latest-selection-http.test.ts`。

**Interfaces:** Consumes Task 2 选择器；Produces Spec 中全量 LatestSelectionResponse、定向 LatestSingleResponse。保留旧请求成功形态及历史 SDK 校验分工，仅对旧请求排除带新增原生构建号限制的 Release。

- [ ] 构造同一个 createApp 实例的全量与定向 app.inject 用例；user_demo_A 且两版本条件匹配时命中 gray V8，user_demo_B/匿名选 full V7；若 full V9 兼容则 A 也返回 V9。
- [ ] Schema 接收精确 userId/versioncode/lynxSdkVersion 字段和 harmony 平台，验证重复参数、整数、SDK 版本及缺失字段。所有新字段均未提供时才走旧分支；只传 userId 不能静默绕过版本校验。
- [ ] 显式测试 maxVersionCode 和 SDK 上下界；新请求 JSON 回传目标平台的有效 versionCodeRange。旧请求只能取无需缺失上下文即可判断可用的 full。
- [ ] 返回每 App 唯一的 bundleList 或 directive；App 枚举包括只有灰度的 App；未知 appId 给明确 not-found，不能删除其他 App State。
- [ ] 实现 private/no-cache + 条件 GET：先按当前上下文选择，再算响应 ETag；A 的 validator 对 B 不得返回可复用 A 内容的 304。
- [ ] 旧 policy/match 委托统一选择器并返回既有字段；旧 manifest endpoint 仍按 releaseId 提供内容，不在本轮另加用户认证系统。
- [ ] 测试同 releaseId gray→full 的 selection 变化会改变响应和 ETag；fallback 从 enabled→disabled 后允许新修订恢复远程。
- [ ] 跑完 harmony 创建→发布→数据库读取→latest→manifest→report 的接口链，确保各层均无 android/ios 写死过滤。报表/告警中的平台标签也不能把 Harmony 当 Android。
- [ ] `pnpm test` 和 `pnpm typecheck` 以及专用数据库集成测试通过，输出 Server HTTP 响应/断言证据，更新 Server/Contracts 文档；服务端验收完成才允许开始 Task 4。

请求构造必须是实际 URL 编码，不能拼接未编码用户字符串：

```ts
const query = new URLSearchParams({
  env: "TEST", hostApp: "capp", platform: "harmony",
  userId: "user_demo_A", versioncode: "25", lynxSdkVersion: "4.0.0",
});
const requestURL = `/api/ota/v1/releases/latest-bundle-list?${query.toString()}`;
```

## Task 4：iOS 注册身份、State 与运行态

**Files（Client）:**

- Modify：`ios/LynxShellKit/LynxRouter.swift`、`ios/LynxShellKit/OTA/LynxOtaRuntime.swift`、`ios/LynxShellKit/LynxShell.swift`。
- Modify：`ios/OtaIOSSDK/Sources/OtaIOSSDK/Models.swift`、`OtaHTTP.swift`、`OtaSDK.swift`、`ContentAddressedOtaStore.swift`。
- Create：`ios/OtaIOSSDK/Sources/OtaIOSSDK/OtaUserContext.swift`、`ios/OtaIOSSDK/Tests/OtaIOSSDKTests/OtaUserSelectionTests.swift`。
- Modify：`ios/Tests/UITests/LynxShellUITests.swift`、`ios/LynxShellSample/App/SceneDelegate.swift`、Sample Launcher/Tab。
- Modify：`scripts/ota-store-v3/local-server.mjs`、`playground/scripts/generate-ota-store-v3-fixture.mjs`。
- Create：`scripts/ota-store-v3/assert-user-gray-results.mjs`、`docs/ios-ota-user-gray-test-report.html`。

**Interfaces:** Consumes Server 已通过验收的两种响应；Produces Spec 的 MainActor Router 注册/清除方法、带 StoredSelection 的 current/previous/candidate，以及 epoch-aware 的 Tab/导航租约。

- [ ] 先补 HTTP 请求捕获测试：所有全量/定向/主动/repair latest 均带 versioncode、lynxSdkVersion、platform=ios；userId 有注册则带，匿名省略；Bundle URL 和下载 header 不含用户身份。
- [ ] 增加宿主 versionCode 配置，默认只接受纯正整数 CFBundleVersion；分段构建号要求显式正整数覆盖，不删点/不取第一段/不用版本名称代替。lynxSdkVersion 与打包 Runtime 一致。
- [ ] 实现同步内存注册屏障、install 前暂存和重复注册幂等；网络同步异步进行，不能让 UI 线程等待请求。
- [ ] 加 epoch 到在途任务和 trial 健康回调，在接受 response/写 State/promote 前复核；policyRevision 以规范化十进制整数比较并在决策接收与激活前检查。
- [ ] 存储每个指针的 StoredSelection 及 State.lastDecision；同 releaseId 更改类型也提交元数据；unknown 历史指针先回 embedded，CAS 可复用。上报使用操作捕获的上下文，不继续读取安装时固定 userId。
- [ ] Tab 观察身份代际：身份变化时重建，普通后台 OTA 不自动重建；Snapshot 停止接纳旧身份子导航，已有 lease 直到 view 销毁再释放。
- [ ] Swift 断言覆盖 Task 7 C01–C22 的适用项。核心测试例：延迟 A 的 latest 响应，先完成 B 注册和同步，再放行 A，确认 State/current/Tab 均未回到 A。
- [ ] 执行 `swift test --package-path ios/OtaIOSSDK --no-parallel`，再 `python3 scripts/static_check_android_ios.py --quiet`。
- [ ] 在当前可用 Simulator 上构建/运行 `LynxShell`，记录设备 UDID；跑匿名→A灰度→B正式→A→更高全量→V5回滚，生成 HTML 截图和请求计数证据。报告通过后进入 Android。

宿主调用示例（实施后可编译）：

```swift
// 用户恢复后，在 install 前或后调用都合法。
LynxRouter.registerOtaUserId("user_demo_A")
// 退出登录。
LynxRouter.clearOtaUserId()
// 测试面板需要等下载完成时使用已有接口，合并同代际注册触发的同步。
let synchronized = await LynxRouter.refreshAllOtaBundles()
```

## Task 5：Android 按相同契约实现并验收

**Files（Client）:**

- Modify：`android/lynx-shell/src/main/java/com/example/lynxshell/LynxRouter.kt`、`ota/ActivityBundleRuntime.kt`、`tab/LynxTabFragment.kt`。
- Modify：`android/lynx-shell/src/main/kotlin/com/example/lynxshell/ota/LynxOtaConfig.kt`、`LynxOtaRuntime.kt`。
- Modify：`android/lynx-shell/src/main/kotlin/com/ota/android/sdk/OtaApiClient.kt`、`OtaModels.kt`、`OtaSdk.kt`、`ContentAddressedOtaStore.kt`。
- Create：`android/lynx-shell/src/main/kotlin/com/ota/android/sdk/OtaUserContext.kt`、`android/lynx-shell/src/test/kotlin/com/ota/android/sdk/OtaUserSelectionTest.kt`。
- Modify：`android/app/src/main/java/com/example/lynxshell/sample/LynxShellSampleApplication.kt`、Sample Launcher/Tab。
- Create：`docs/android-ota-user-gray-test-report.html`。

**Interfaces:** Consumes 已在 iOS 验证的同一 fixture；Produces MainThread Router 注册接口以及等价 Store/Runtime 行为。

- [ ] 编写 HTTP URL/headers 捕获、用户切换、修订降序响应和 candidate token 测试。
- [ ] versioncode 默认来自 longVersionCode/低版本 versionCode，不从 versionName 取；保留旧 buildNumber 上报含义，HTTP 字段新增精确 versioncode。全量、定向、repair、主动刷新统一传实际 Lynx SDK 版本。
- [ ] 使用 Atomic/锁保护用户上下文；注册先更新 epoch，再在已有单线程刷新队列整理 State 与合并全量同步。缺包 repair 也必须遵守提交屏障。
- [ ] 实现相同 selection/lastDecision 元数据、有效 previous/embedded 选择、unknown 元数据处理和同包 gray→full 更新；对象指纹 SHA cache 保留。上报从操作上下文取身份，迟到事件不改标为新账号。
- [ ] Fragment 身份变化重建 generation，当前用户无网络时仍不得选旧灰度；释放视图后才释放 lease。
- [ ] 执行 `gradle -p android :lynx-shell:testDebugUnitTest :app:assembleDebug --no-daemon` 和 `python3 scripts/static_check_android_ios.py --quiet`。
- [ ] 用连接的测试设备或 Emulator 跑 Task 7 的同一序列，保存 APK 身份/设备/截图/请求计数/State；生成 Android HTML，通过后进入 Harmony。

```kotlin
LynxRouter.registerOtaUserId("user_demo_A")
LynxRouter.clearOtaUserId()
LynxRouter.refreshAllOtaBundles { success ->
    // success 为当前身份最后一轮同步结果；Demo 据此更新测试状态。
}
```

## Task 6：Harmony 同义实现，无 candidate

**Files（Client）:**

- Modify：`harmony/lynx_shell_kit/src/main/ets/routing/LynxRouter.ets`。
- Modify：`harmony/lynx_shell_kit/src/main/ets/ota/OtaModels.ets`、`OtaApiClient.ets`、`LynxOtaRuntime.ets`、`ContentAddressedOtaStore.ets`。
- Create：`harmony/lynx_shell_kit/src/main/ets/ota/OtaUserContext.ets`。
- Modify：`harmony/lynx_shell_kit/src/main/ets/pages/LynxTabContainer.ets`、`harmony/lynx_shell/src/main/ets/entryability/EntryAbility.ets`、`harmony/lynx_shell/src/main/ets/pages/Index.ets`。
- Create：`scripts/ota-store-v3/run-harmony-user-gray-tests.sh`、`docs/harmony-ota-user-gray-test-report.html`。

**Interfaces:** Consumes 同一新参数契约与无 candidate 的测试子集；Produces registerOtaUserId、clearOtaUserId 和同义身份/State/导航处理。

- [ ] Fixture 首先记录 Want 注入模拟用户和请求平台，确保正式验收使用已扩展的 platform=harmony，而非伪装 Android。
- [ ] 新增 userId/versionCode/lynxSdkVersion 配置和 UI 线程注册屏障，使用已有 OtaOperationQueue 整理归属与刷新；延迟 response 在写 State 前校验 epoch。versioncode 读取自身包信息 appInfo.versionCode，不能取固定 ShellConstants.BUILD_NUMBER。
- [ ] 全量/定向/repair 统一发 platform=harmony，移除 Demo 默认 serverPlatform=android 覆盖；拒绝未知平台，HTTP 失败不静默重发成 Android 请求。
- [ ] ArkTS 解析序号为字符串并用长度/逐字符数值比较或 SDK 支持的 BigInt；禁止 Number 转换。写测试使 `9007199254740993` 大于 `9007199254740992`。
- [ ] 实现 current/previous/embedded 和 Tab/Snapshot 规则，candidate 用例明确标为设计不适用，不记为通过。
- [ ] `python3 harmony/scripts/check_harmony_shell.py --quiet`，DevEco Hvigor 分别构建 HAR、完整 App；通过 HDC 完成 Task 7 用户场景。
- [ ] 生成 Harmony HTML，附设备、版本、请求与实际页面截图；三端报告都关联同一 fixture 配置。

```typescript
LynxRouter.registerOtaUserId('user_demo_A');
LynxRouter.clearOtaUserId();
const synchronized = await LynxRouter.refreshAllOtaBundles();
```

## Task 7：统一测试矩阵与交付门禁

下面矩阵为待执行标准。测试命名和 expected output 应进入对应自动化文件，不能仅靠手工报告打勾。

| ID | 输入/操作 | 必须断言 |
|---|---|---|
| S01 | full5、gray6，A 白名单 | A=gray6；B/匿名=full5 |
| S02 | 再创建发布 full7 | A/B/匿名都为 full7 |
| S03 | 再发布 gray8 | 仅 A=gray8，其他 full7 |
| S04 | gray8 规则 DISABLED | 所有用户回 full7 |
| S05 | 解绑规则、旧 gray 仍 ACTIVE | 旧 gray 不落入正式候选 |
| S06 | gray8 原 Release 全量化 | 同 releaseId 变 full；ETag/State 归属都更新 |
| S07 | full9 不兼容、full7 兼容、gray8 兼容 | A=gray8，B=full7 |
| S08 | App 只有 gray | 全量枚举不漏 App；非白名单收到无可用指令 |
| S09 | 定向和全量查询同一个 App | releaseId/kind/revision 一致 |
| S10 | 旧请求不带三个新参数 | 历史无新构建号限制的正式发布仍可读取，旧成功结构保留 |
| S11 | duplicate userId/超长/控制字符 | 400；空白变匿名；大小写/前导零保留 |
| S12 | A ETag 发给 B，规则修订后旧 ETag | 不返回会复用错误选择的 304 |
| S13 | 同库并发发布/规则更改 | 原子状态与递增 revision，无混合快照 |
| S14 | 修改旧 Release 状态/重新发布旧灰度 | releaseSequence 不变，不能超过更高 full |
| S15 | V10 显式回滚 V5 | 客户端接受 V5；旧 V10 请求不能恢复它 |
| S16 | 开/关强制 embedded | 开时明确回退，关后新修订恢复远程选择 |
| S17 | targetRule 不存在或 scope 错误 | 发布失败且 Release 没有提前 ACTIVE |
| S18 | versioncode 范围 [120,199]，请求 119/120/199/200 | 仅 120/199 可用，上下界包含 |
| S19 | SDK 范围 [4.0.0,4.1.0]，请求 3.9.0/4.0.0/4.1.0/4.2.0 | 仅边界内可用；另验证 4.10.0 > 4.9.0 |
| S20 | A 命中 gray8，但原生或 SDK 任一不兼容 | 继续查其他兼容 gray/full，不能直接返回 gray8 |
| S21 | gray9 不兼容、gray8 兼容、full7 兼容 | A 返回 gray8，而非漏查直接 full7 |
| S22 | 同 Release Android [120,199]、iOS [800,899]、Harmony [20,29] | 各自按目标平台范围过滤，不采用 platforms[0] 范围 |
| S23 | Harmony 创建/发布/Prisma回读/latest/manifest/report | platform 始终为 harmony，包仅 android 时不返回它 |
| S24 | 范围在创建/详情/发布/跨环境提升的往返 | versionCodeRange/platformVersionCodeRanges/lynxSdkRange 保真 |
| S25 | 只 userId / 只 versioncode / 缺 SDK / 新请求无 platform | 400 明确字段缺失，不退回不受限查询 |
| S26 | 负数/小数/科学计数/超限versioncode、非法SDK | 400；大于2^53合法整数按字符串精确比较 |
| S27 | 旧请求缺构建号，只有受限 full；或范围完全缺省 | 前者不可放行，后者仍可按旧响应提供 |
| S28 | 同用户不同 versioncode/SDK、旧 ETag | 不复用错误上下文决策；兼容 full 更高时仍覆盖 gray |
| C01 | install 前注册 A | 一次启动全量请求，身份 A，无匿名重复 |
| C02 | 重复注册规范化后的同一 A | 零新增同步、零 Tab 重建 |
| C03 | 匿名→A 登录 | 绕过 30 分钟，完成灰度选择 |
| C04 | A→B / A→匿名 | 新页面与 Tab 不使用 A 灰度 |
| C05 | C04 且离线，没有已存正式版本 | embedded 可用；无 embedded 显式错误 |
| C06 | A 响应被暂停，B 已完成同步后放行 | A 不提交 State、不更新 B 门控、不 promote |
| C07 | A candidate 首屏迟到，已换 B candidate | 不能确认或清除 B 的 candidate |
| C08 | gray releaseId 不变但全量化 | 零 Bundle 下载，元数据变 full，可跨账号使用 |
| C09 | userId 切换时已有 live lease | GC 不删除 live 对象；view 销毁后可回收 |
| C10 | 存在旧用户 previous | 不跨用户回滚；允许适用全量或 embedded |
| C11 | 冷启动磁盘 gray/unknown 指针 | 匿名禁用灰度；unknown 等重新确认，CAS 复用 |
| C12 | 当前用户普通后台检查完成，切 Tab | 活体 Tab 保持实例，切换新增请求数 0 |
| C13 | 主动刷新后重载 Tab | 展示最新决定的 releaseId 和 full/gray |
| C14 | V1→V2：100 包中仅 050 变化 | Bundle GET=1、CAS 新增=1、未变复制=0 |
| C15 | B 可复用 A 下载过的相同对象 | bytes复用，选择授权仍按B响应，不复用A决策 |
| C16 | 新修订 use_embedded 后收到旧响应 | 不恢复旧 remote；重启仍遵守已确认指令 |
| C17 | 全量/定向/repair/主动刷新请求抓取 | 三字段与真实原生/Runtime 一致，字段名固定 versioncode |
| C18 | Android versionName=1.0.0，versionCode=120 | HTTP versioncode=120 |
| C19 | iOS CFBundleVersion=800；或1.2.3无显式覆盖 | 前者发送800；后者OTA配置失败但本地包可继续用 |
| C20 | Harmony 自身versionCode=25，旧Demo兼容值曾为android | HTTP platform=harmony、versioncode=25，无重试降级 |
| C21 | 宿主版本/SDK 改变后离线读取旧 State | 重新检查本地兼容范围；不符合则回 embedded |
| C22 | 内置下载脚本传目标versioncode/SDK且无userId | 只下载兼容正式基线，永不内置个人灰度 |

- [ ] Fixture 同时包含 full5/gray6/full7/gray8/gray9 和原生/SDK兼容范围；不要每次重新随机构建全部 100 包。页面固定显示 Bundle 自身标记；原生面板显示 releaseId、versioncode、SDK版本、sequence、selection kind、ruleId、epoch 和请求数，不输出真实用户ID。
- [ ] 客户端阶段同步手动内置下载脚本参数：目标平台、versioncode、lynxSdkVersion 必须与打包一致，userId 永远省略。
- [ ] 服务端真实 createApp 测试证明选择算法；本地 fixture 证明设备接入。两种证据都必须存在，不能用假服务选择结果替代真实 Server 单测。
- [ ] Node 结果断言读取三端 JSON 证据，校验每个适用用例都有通过/失败/未执行状态；截图与结果使用同一 runId。
- [ ] 三端 HTML 都写明构建提交、平台系统、fixture、测试结果、截图、网络计数、Store 指针；未跑或设备不支持不能标通过。
- [ ] 同步 Client 的 `OTA_SERVER_API_CONTRACT.md`、`MODULE_INTEGRATION.md`、`PROJECT_MAP.md`、README、各 Module AGENTS，Server/Contracts 文档及 Obsidian 索引。
- [ ] 只有在新数据/老客户端兼容/旧State读取/用户切换/全量压过灰度/回滚全部有证据后，才将设计状态改为已实现；部署、npm 发布、PR 合并分别按当时授权执行。

## 本次方案自检

- 用户指定现有 GET 路径：Task 3。
- 精确三个新参数、原生构建号范围和 SDK 过滤：Task 1–3、S18–S28。
- Harmony 全链平台枚举及多平台范围持久化：Task 1/3/6、S22–S24、C20。
- 必须先完成 Server，再接客户端：Task 3 出口门禁。
- Router 注册/更新/清除、install 前后及重复注册：Task 4–6。
- 更高全量优先及同 release 全量化：Task 1–3、S02/S06/C08。
- 账号切换、candidate、在途请求、Tab、GC、离线：Task 4–7。
- 完整 Manifest、100 包增量、旧接口兼容、server rollback：Task 3/7。
- 所有新增字段和接口均在技术设计或任务接口块定义。文件路径已按当前源码核实；新文件明确标注 Create。
