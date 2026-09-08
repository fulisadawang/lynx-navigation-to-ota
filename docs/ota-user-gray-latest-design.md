# latest 接口 userId、versioncode、lynxSdkVersion 与鸿蒙技术方案（修订 2）

状态：2026-09-06 本地实现与调整后的验收范围已完成：Server/Contracts 自动测试通过，iOS 模拟器通过，Android/Harmony 非设备测试与构建通过；未发布或部署。原设计日期：2026-09-05。三端 HTML 与逐项证据入口见 [最终验收索引](ota-user-gray-acceptance-matrix.md)。

验收范围最新调整：用户明确 Android/Harmony 不走模拟器测试，后两端改为代码、自动/协议测试、构建及明确未设备验收的HTML。原设备场景保留为可选后续计划。

修订 2 按用户最新要求替代上一版的请求设计：先完成工作区独立 LynxOtaServer 的接口及数据筛选，再接三端客户端。新增 Query 精确为 `userId`、`versioncode`、`lynxSdkVersion`，platform 增加 `harmony`；取消上一版要求客户端传 selectionProtocol 的设计。用户再次确认：兼容的全量 V7 高于灰度 V6 时必须返回 V7。

## 1. 已确认目标与结论

1. 直接改造 `GET /api/ota/v1/releases/latest-bundle-list`，不新增 resolve 接口。
2. 原生宿主向 Router 注册业务 `userId`；启动全量、定向检查、主动刷新、缺包修复同时带原生 `versioncode` 和实际 `lynxSdkVersion`。
3. 先根据 userId 确定可访问灰度候选，再检查原生 versioncode 与 Lynx SDK 兼容性，最后与兼容全量比较。**更高版本的全量发布覆盖较旧的灰度发布**。
4. Manifest 继续是完整快照，CAS 继续只下载缺失 SHA；Native Tab 普通切换不联网。
5. 以下保留实施依据；实际完成范围以最终验收索引为准。Android/Harmony 不以宿主测试或构建代替设备证明。

## 2. 实施前核实的源码基线（非本次改完后的行为）

| 项目 | 本次核实基线 | 关键事实 |
|---|---|---|
| 客户端仓库 | `codex/rewrite-project-readme` / `fdcdc53` | 三端默认走 latest；Android/iOS 配置有 userId，但 latest 请求没用；Harmony 配置没有 userId |
| 独立 LynxOtaServer | `test` / `e44215e` | latest 排除灰度；policy/match 白名单命中即返回，没有与更高全量比较 |
| 独立 LynxContracts | `test` / `e4aaf67` | 公共契约在 packages/shared；Server 当前依赖已发布的 `@cclx/lynx-ota-contracts` |

事实源路径均相对对应仓库根：

- Server：`src/modules/release/schema.ts:42`、`src/modules/release/service.ts:63`、`src/modules/policy/service.ts:171`、`src/modules/policy/matcher.ts:44`。
- Server：`prisma/schema.prisma` 有 `createdAt/updatedAt/publishedAt/publishType`，没有可比较的 Release 整数序号。`releaseId` 是身份标识，`appVersion` 是原生宿主兼容版本。
- Server：Release 有 minAppVersion/maxAppVersion（版本名称）和 lynxSdkRange，但没有本次所需的原生整数 versioncode 范围。Rule 表虽然遗留 buildNumberRange，当前规则创建 Schema 和匹配逻辑没有接通它，不能认为已经支持 versioncode。
- Server：`src/storage/prisma.ts` 的 parseReleasePlatforms 仅保留 android/ios，未知主平台会回落 Android。因此 Harmony 必须连同数据库读写映射、发布和共享类型一起支持，不能只改 Query 枚举。
- Server：`src/modules/policy/service.ts` 未检查规则 `status`；该缺口需要修复。`isGrayRelease` 应优先读取发布元数据，不能仅靠仍绑定的规则推断发布类型。
- Server：`src/modules/rollback/service.ts` 已有停发其他 ACTIVE、禁用规则及恢复目标的操作，但尚未提供新版 latest 的明确回退指令。
- Client：`android/lynx-shell/src/main/kotlin/com/ota/android/sdk/OtaApiClient.kt`、`ios/OtaIOSSDK/Sources/OtaIOSSDK/OtaHTTP.swift`、`harmony/lynx_shell_kit/src/main/ets/ota/OtaApiClient.ets`。

以上缺口是本次实现前的事实；本次已接通 latest 及共享选择逻辑，不能将基线描述当作改完后的代码。线上部署 SHA 未做核验。

## 3. 版本大小和策略修订必须分开

### 3.1 releaseSequence：Bundle 版本的固定顺序

新增 `releaseSequence`，由服务端在创建 Release 时分配并持久化，作用域为 `(env, hostApp, lynxAppId)`。数据库使用 BigInt，HTTP 使用十进制字符串，客户端不得用浮点数或字符串字典序比较。

- 创建顺序分配：V5 对应序号 5，V6 对应序号 6；这是本方案对“版本更高”的明确定义。
- 全量和灰度使用同一个序列，平台先过滤，再比较序号。
- 修改白名单、禁用/启用规则、验证、重新发布同一 Release，都不改变 releaseSequence。
- releaseId、updatedAt、publishedAt、原生 appVersion 均不能代替这个序号。
- 并发创建使用数据库 scope counter + 事务，不能使用 `MAX(sequence)+1`；唯一约束为 `(env, hostApp, lynxAppId, releaseSequence)`。
- 如将来需要 CI 显式传业务语义版本，可增加展示字段，但本次排序只使用服务端序号。

存量数据采用一次受控回填：每个 scope 按 `createdAt ASC, releaseId ASC` 分配序号。相同创建时间的历史先后无法恢复，以此稳定规则确定迁移顺序并输出映射供审阅；不将其宣称为准确历史发布时间。新数据不再使用这种兜底排序。

### 3.2 policyRevision：版本选择规则的修订号

新增每个 `(env, hostApp, lynxAppId)` 的 `policyRevision`，同样使用 BigInt / 十进制字符串。发布、规则绑定/状态/白名单变动、停发、回滚、强制 embedded、兼容条件变更都在数据库事务中增加它。

它解决“旧请求晚回来覆盖新决定”，不用于判断 Bundle 内容更新。客户端按同一用户上下文及平台记录已接受的最高修订号，拒绝更旧响应；相同修订号允许修复下载。

示例：服务端从 V10 回滚到 V5，V5 的 releaseSequence 仍为 5，但 policyRevision 从 20 增加到 21。客户端必须接受新决定，不能以 `5 < 10` 拒绝回滚。

## 4. 唯一版本选择规则

先固定 scope：环境、hostApp、appId、platform。只有已发布 ACTIVE 且平台匹配的 Release 能进入本次查询。之后先筛用户灰度资格，再对灰度与全量分别执行相同的 versioncode / lynxSdkVersion 检查；白名单不能绕过兼容条件。

1. 强制 embedded 开关优先，返回明确 `use_embedded`。
2. 若有有效的服务端回滚目标，返回该目标（或 embedded），不进行普通最高版本竞争。
3. 根据 userId 取得 ENABLED、userWhitelist 精确命中的灰度规则，建立目标集合；匿名的灰度目标集合为空。
4. 过滤该集合中 versioncode 与 lynxSdkVersion 不兼容的 Release，再取最高 releaseSequence，记为 G。同时对 FULL 集合做相同的兼容过滤，取最高者 F。不能在遇到第一个不兼容灰度时立即放弃其他兼容灰度，也不能先选最高全量再让客户端发现不兼容。
5. F 与 G 都存在：`G.sequence > F.sequence` 才返回 G，其余返回 F。
6. 只有 F 返回 F；只有 G 且用户匹配返回 G；都没有返回 `no_compatible_release`。
7. 同一 Release 同时被规则引用并已全量发布时视为 FULL；若同一目标匹配多条规则，仅用 priority 降序、ruleId 升序确定诊断 ruleId。规则优先级不能让旧版本压过新版本。

| 可用全量 | 白名单灰度 | 当前用户 | 应返回 |
|---|---|---|---|
| V5 | V6 | 命中 | 灰度 V6 |
| V7 | V6 | 命中 | 全量 V7 |
| V7 | V8 | 未命中/匿名 | 全量 V7 |
| V7 | V8 | 命中 | 灰度 V8 |
| V7 | V8 规则已禁用 | 命中用户 | 全量 V7 |
| V7 不兼容、V5 兼容 | V6 兼容 | 命中 | 灰度 V6 |
| 同一 V8 已全量化 | 规则仍指向 V8 | 任意用户 | 全量 V8 |
| 无 | V6 | 命中 | 灰度 V6 |
| 无 | V6 | 未命中 | no_compatible_release |
| V10 | V11 | 服务端明确回滚 V5 | 兼容的目标 V5 |

全量与定向调用同一选择器；全量从已登记 Lynx App 列表枚举，不能先取“有全量版本的 App”再叠加灰度，否则只有灰度版本的 App 会漏掉。批量加载 Release、规则和控制状态，避免每个 Bundle 查询一次 DB。

既有 `policy/match` 复用选择/排序内核，并保留原有 pageId、appVersion、nativeProtocolVersion 检查；新增 versioncode 为可选输入，有该范围的 Release 在缺字段时不允许通过。新版 Router 不调用 policy/match，latest 以整个 App Release 为单位，不要求 pageId，也不拼接不同 Release 的页面。

### 4.1 原生 versioncode 的比较

查询字段精确使用全小写 `versioncode`。值使用十进制整数字符串：规范化后范围为 1 到 9223372036854775807。服务端用 BigInt 比较，不用浮点、不用小数版本比较、不把字符串 `100` 排在 `99` 前。

新增 Release 约束 `versionCodeRange: { min?: string, max?: string }`，上下界包含。举例 min=120、max=199，则 119 不匹配，120/150/199 匹配，200 不匹配。只写 min 表示无上限，只写 max 表示无下限；完全未配置表示没有这项限制，而不是默认不兼容。新字段不能从 minAppVersion 自动转换。

同一个 Release 可能支持多个平台，所以新增并完整持久化 `platformVersionCodeRanges`：

```json
{
  "platformVersionCodeRanges": {
    "android": { "min": "120", "max": "199" },
    "ios": { "min": "800", "max": "899" },
    "harmony": { "min": "20", "max": "29" }
  },
  "lynxSdkRange": { "min": "4.0.0", "max": "4.1.0" }
}
```

某平台配置存在时使用其范围，否则使用公共 versionCodeRange；平台空对象表示明确无此限制。实际 latest 响应只返回目标平台最终采用的 versionCodeRange。不能像当前内存仓储那样只按 platforms[0] 解析一次就丢掉其他平台配置。创建、详情、校验、发布、跨环境提升/复制、Prisma 和内存仓储都要保存这些字段；旧元数据空值保持空，不伪造限制。

### 4.2 lynxSdkVersion 的比较

复用 Release 现有 lynxSdkRange.min/max，端点包含；按数字段比较，4.10.0 大于 4.9.0。查询及新发布限制统一校验为稳定版本的 1–3 个非负整数段并补齐为三段，不接受未知语义的预发布、通配符或任意表达式；历史非法范围不当作无约束，需修复元数据。

未设置 lynxSdkRange 表示无这项额外限制。设置了范围却缺少/传错 lynxSdkVersion 时不能放行。选择阶段必须同时满足 versioncode 范围和 SDK 范围。

原有 minAppVersion/maxAppVersion 与 nativeProtocolVersionRange 不重命名、不映射成 versioncode；旧 policy/match 和客户端已有的额外校验保留。新版 latest 的新增服务端筛选项只负责用户指定的 versioncode 与 SDK；若发布还依赖版本名称/协议限制，继续由原有客户端门禁校验，不能声称这两个新参数代替所有原生兼容条件。

## 5. 现有 HTTP 接口扩展

### 5.1 请求

保留路径、GET 方法、全量/定向语义。新增的业务 Query 只有用户指定的三个字段；新版 SDK 总是携带 versioncode 和 lynxSdkVersion，userId 取当前注册身份。响应通过 selectionSchemaVersion 自描述，不要求业务额外注册协议参数。

| Query | 规则 |
|---|---|
| env、hostApp | 保持已有必填语义 |
| platform | 新参数查询必填，android/ios/harmony；旧无新参数查询维持可选 |
| lynxAppId | 不传为全部 App，传入 8 位数字则定向 |
| userId | 可选字符串；去首尾空白，空值等同匿名；保留大小写和前导零；最长 256 UTF-8 字节；不接受重复 query、对象或控制字符 |
| versioncode | 新参数查询必填，原生构建版本代码；正整数字符串，不是 appVersion/versionName，也不用于比较两个 Release |
| lynxSdkVersion | 新参数查询必填，当前实际装载的 Lynx Runtime 稳定版本，标准化如 4.0.0 |

```http
GET /api/ota/v1/releases/latest-bundle-list?env=TEST&hostApp=capp&platform=harmony&userId=user_demo_A&versioncode=25&lynxSdkVersion=4.0.0
```

定向请求只再加 lynxAppId。无 userId/空 userId 按匿名查兼容全量。只要出现任一新字段（非空 userId，或出现 versioncode/lynxSdkVersion），就要求 versioncode + lynxSdkVersion + platform 完整，否则 400 并列出缺失字段；禁止悄悄退回不带兼容限制的旧查询。

三个新字段完全不出现时为旧模式：只选全量，保留旧成功结构和已有 SDK/版本名称由旧客户端校验的行为，避免 Server 先上线就突然让旧 App 取不到全部历史包。但**配置了新增 versionCodeRange 的 Release 不向无 versioncode 的旧请求返回**，因为旧客户端无法执行这项新限制；此时可回到旧兼容全量或 404。新增范围不自动回填到历史 Release，后续受限发布需确认对应新客户端已接入。这是先 Server 后 Client 的发布兼容边界。

### 5.2 响应

继续保留现有成功形态：全量返回 bundleLists 包装，定向返回单个快照。新参数响应增加 selectionSchemaVersion=1 和 selection 记录。全量中没有远程可用版本的 App 进入 directives；定向同类结果返回明确 directive 对象。每 App 必须恰好有一个结果，不能把空列表、网络失败和服务端撤销混为一谈。

```ts
type DecimalSequence = string; // 仅非负十进制整数，服务端用 BigInt 比较
type SelectionKind = "full" | "gray";
interface VersionCodeRange { min?: string; max?: string }
interface SelectionMetadata {
  kind: SelectionKind;
  ruleId?: string;             // 只有 gray 提供
  policyRevision: DecimalSequence;
  reason: "latest_full" | "matched_gray" | "server_rollback";
}
interface LatestQueryContext {
  env: string;
  hostApp: string;
  platform: "android" | "ios" | "harmony";
  userId?: string;
  versioncode: string;
  lynxSdkVersion: string;
  lynxAppId?: string;
}
type SelectedBundleList = LatestBundleList & {
  selectionSchemaVersion: 1;
  releaseSequence: DecimalSequence;
  versionCodeRange?: VersionCodeRange;
  selection: SelectionMetadata;
};
interface SelectionDirective {
  lynxAppId: string;
  action: "use_embedded" | "no_compatible_release";
  policyRevision: DecimalSequence;
  reason: string;
}
interface LatestSelectionResponse {
  selectionSchemaVersion: 1;
  env: string;
  hostApp: string;
  platform: "android" | "ios" | "harmony";
  bundleLists: SelectedBundleList[];
  directives: SelectionDirective[];
}
type LatestSingleResponse = SelectedBundleList | {
  selectionSchemaVersion: 1;
  env: string;
  hostApp: string;
  platform: "android" | "ios" | "harmony";
  decision: SelectionDirective;
};
```

`LatestBundleList` 指现有 LynxContracts 中的完整快照，继续包含 changedBundles、size/SHA/URL/兼容范围。选包响应不回传白名单，不回传原始 userId。无可用版本返回明确 directive，不能用空数组同时表达撤销版本、网络错误和没有更新。

- `use_embedded`：停止新页面选择远程 current/previous/candidate；使用内置，无内置则返回可识别错误，不继续运行被服务端撤下的包。
- `no_compatible_release`：本次成功决策没有适用远程版本，新入口使用 embedded；旧活体页面由宿主管理退出。
- 网络/5xx/解析失败：保留同一用户可用的本地版本；用户已变化时绝不能保留上一用户灰度作为新入口。
- 返回同一个 releaseId 但 selection 从 gray 变 full 时，仍须原子更新 State 元数据；不能被 alreadyActive 快捷分支跳过。

### 5.3 HTTP 缓存与请求数

新参数响应返回 `Cache-Control: private, no-cache`。服务器在计算当前用户选择后再比较 ETag，ETag 覆盖 scope、完整选择结果及 policyRevision；客户端 key 必须包含 userId 对应摘要、platform、versioncode、lynxSdkVersion 及全量/定向 scope。更换用户或宿主/Runtime 版本不能复用旧决策。304 只有在相同 key 存在已验证响应时才能使用。

启动一次全量 GET，页面间隔到期一个定向 GET；不逐 Bundle 调 policy/match。服务端查版本始终返回完整快照。Bundle CDN URL 不增加 userId、不转发 OTA token；同 App ID 的相同 SHA 对象继续复用。

手动内置 Bundle 下载脚本在客户端阶段补充目标平台的 versioncode、lynxSdkVersion 参数，并始终省略 userId，确保内置的是适用于本次原生打包版本的正式基线。已有旧脚本仍能请求无上下文兼容版本，但无法选择有新限制的 Release。普通请求中不得日志输出完整含用户 query 的 URL。

## 6. Router 注册 userId

三端统一方法名 `registerOtaUserId`；重复调用可更新身份。`clearOtaUserId` 等价于注册匿名。方法只开放给原生宿主，不添加页面 Bridge 方法。

```kotlin
// Android：在主线程调用；返回时已切换内存身份、旧入口资格已失效。
@MainThread fun registerOtaUserId(userId: String?)
@MainThread fun clearOtaUserId()
```

```swift
// iOS：不等待网络，完成本地身份切换后返回。
@MainActor public static func registerOtaUserId(_ userId: String?)
@MainActor public static func clearOtaUserId()
```

```typescript
// HarmonyOS：UI 线程调用。
static registerOtaUserId(userId?: string): void
static clearOtaUserId(): void
```

方法调用方式统一为 `LynxRouter.registerOtaUserId(...)`。初始配置已有 userId 的 Android/iOS 保留兼容，并给 Harmony 增加同义字段。优先级：显式 Router 注册（包括显式匿名）高于安装配置 userId。

- install 前：允许注册，Router 暂存初始上下文；install 直接使用该身份执行一次启动同步，不先匿名请求再重复请求。
- install 后：新身份生效、identityEpoch 增加，触发一次全量同步；同一规范化 userId 重复注册不触发网络和 Tab 重建。
- 登录态尚未恢复：宿主可先匿名启动；恢复用户后注册并重新同步。若要冷启动只发一次，必须在 install 前恢复并注册身份，不能靠客户端猜用户。
- 原始 userId 由宿主登录系统管理；OTA 不另存明文用户账号。匿名视为明确身份。
- 若调用方需要等待下载完成，复用现有 `refreshAllOtaBundles` 完成接口：对注册已触发的同 epoch 全量任务进行合并，不能再次排队相同全量请求；现有普通主动刷新语义保留。

内部单一用户上下文至少包含 `normalizedUserId?`、`audienceKey`、`identityEpoch`。audienceKey 可用每次安装持久随机盐 + env/hostApp/userId 的 SHA-256，只用于等值匹配，不承担服务端身份认证；匿名使用固定标志。换 App、重装和宿主切换不共享明文标识。

Android/iOS 既有上报不能继续读取安装时固定的 configuration.userId：检查/下载/激活事件使用触发操作时捕获的上下文，页面事件使用该页面所属上下文，不能在事件晚发时改标为另一个账号。Harmony 本次不扩展未实现的完整指标系统，只保证新增版本选择请求身份正确。

### 6.1 三端 versioncode 与 Runtime 版本来源

| 平台 | versioncode 默认来源 | 补充规则 |
|---|---|---|
| Android | 安装包 PackageInfo.longVersionCode，低版本使用 versionCode | 不使用 versionName；现有 buildNumber 已从该来源生成，但新 Query 名仍精确为 versioncode |
| iOS | Info.plist 的 CFBundleVersion，只有纯正整数时可直接采用 | 若宿主使用 1.2.3 等格式，必须显式配置正整数 versionCode；禁止删点、取第一段或借用 CFBundleShortVersionString |
| Harmony | 宿主自身应用包信息的 appInfo.versionCode | 明确从平台包信息读取，不使用 ShellConstants 的固定 BUILD_NUMBER；默认请求平台改为 harmony |

三端宿主配置统一增加语义字段 versionCode（内部命名），HTTP 编码统一为全小写 versioncode；显式配置优先于原生读取。配置非法时保留可用本地加载，并明确报告 OTA 配置错误，不能发伪造的 0 或静默省略参数。

lynxSdkVersion 取实际接入 Runtime 的版本来源；当前项目冻结值 4.0.0，需与本机打包依赖一致，不能拿 Bundle 的版本或 DevTool 版本代替。Harmony 增加 versionCode/lynxSdkVersion 配置和数据模型，清除 Demo 中 serverPlatform=android 的默认覆盖，未知服务端平台支持不得默默降级。

Android 对 versionCode 与 versionName 的区分见 [Android 官方版本文档](https://developer.android.com/studio/publish/versioning)。CFBundleVersion 可为分段构建号，因此 iOS 的整数归一化需要显式宿主约定，见 [Apple 构建号说明](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html#//apple_ref/doc/uid/TP40009249-SW1)。

### 6.2 切换顺序和在途请求

1. 内存原子切换身份并递增 epoch；从该步骤起，新页面不得选旧用户灰度。
2. 使旧 epoch 的响应、重试、排队同步、Tab load generation 和 candidate 健康回调失效。
3. 取消可取消的请求；不可取消的请求仍必须在解码后、发布 State 前、首屏 promote 前校验 epoch。
4. 清空用户版本决策/ETag 缓存与 30 分钟门控。SHA 文件指纹校验缓存继续有效。
5. 在 Store 队列整理指针；选择已验证全量 current/previous 或 embedded。清除不匹配的 candidate，保留仍被页面 lease 的物理对象。
6. 执行新 epoch 全量同步并分别更新各 App 的 State。单个 App 下载失败不宣称整组全成功；保留该 App 当前身份可用的版本。
7. 初次用户身份变化触发内置 Tab 容器重建到匹配身份的内容；新同步完成后通过宿主确认的 reload 流程消费新版本。

已有页面继续持有旧 lease 直到销毁；它们的旧导航 session 禁止创建新子页或 promote 新身份 candidate。账号切换时原生宿主应关闭/重建旧账号页面，Router 发出仅含 epoch 的类型化上下文变化通知供宿主接入。不能把“拒绝旧 Snapshot 新导航”误实现为强制释放仍展示页面的文件。

## 7. Store v3 元数据与容量

物理布局不变：objects 继续按 App ID + SHA，Manifest 保持不变内容快照，State 指针携带选择记录。不会创建 users/<userId>/Bundle 目录，不按历史登录用户永久保留一份 State。

```ts
interface StoredSelection {
  kind: "full" | "gray";
  audienceKey?: string; // gray 必填，full 不绑定单个用户
  ruleId?: string;
  releaseSequence: string;
  policyRevision: string;
  versionCodeRange?: VersionCodeRange;
  lynxSdkRange?: { min?: string; max?: string };
}
```

给 current、previous、candidate 的每个引用增加 StoredSelection，并增加 `selectionSchemaVersion=1`。CAS 存储格式仍为 v3；在事务提交时将引用与选择记录一次原子持久化。不能只改内存，也不能先写 current 再补归属。

State 还必须持久化 `lastDecision: { audienceKey, clientContextKey, policyRevision, action, targetReleaseId? }`，action 为 `use_release/use_embedded/no_compatible_release`。clientContextKey 是用户摘要、platform、versioncode、lynxSdkVersion 的规范化摘要，防止原生升级后将旧兼容结论带到新构建。lastDecision 不引用 Bundle bytes，也不是额外的 GC root。它与引用变更共用 State 原子写入：收到明确撤销指令后，即使随后进程重启，也不能重新选回远程 current。

接收更高修订时先持久化决策约束，再下载/发布内容；事务激活前复核 lastDecision 与 epoch。新决策已选 full 或其他 gray 后，原 gray 不再作为新页面入口；可先使用仍允许的 full/embedded。网络失败没有产生新决策时，保留原身份可用版本。已显示页面依旧按 lease 生命周期退出，不会被这一元数据更新粗暴删除。

- 新页面选 full 时仍校验已保存的 versionCodeRange、lynxSdkRange 及已有宿主版本/协议限制；gray 则额外校验 audienceKey。宿主升级/降级或 Runtime 改变后，本地校验也必须重新应用这些兼容条件。
- previous 为旧用户灰度时禁止选用；已验证全量 previous 可作为临时本地回退。服务端收到更高修订的明确禁用/embedded 指令后，不允许再次用历史 previous 绕过该指令。
- Android/iOS candidate 的 audienceKey/epoch、ruleId、修订与 trial token 要保持一致；旧 candidate 迟到首屏不能 promote 新 candidate。
- Harmony 不增加 candidate，但必须同样检查 current/previous、Snapshot 和身份变更。
- 同一用户普通后台 OTA 不替换活体 Tab；只有主动刷新/冷启动消费，延续现有约定。
- 没有保留正式远程版本时，退出灰度账号允许先回 embedded，随后联网更新。若需要“离线退出也立即回某个已下载正式版本”，属于额外保留策略，不是本方案默认要求。
- 正常未租用情况下仍只有 current/previous/可选 candidate 指针；旧账号失效记录不额外成为 GC root。活体 lease 和未完成事务仍可能临时保留更多对象，不能承诺物理目录始终恰好两份。

### 7.1 元数据升级与冷启动

- 新 SDK 读取缺少 selectionSchemaVersion 的远程指针时标记 unknown，不假设它一定是 full；允许保留 CAS 待服务器重新确认，不选 unknown 作为新页面版本。
- 同步未完成时使用 embedded；收到相同 releaseId 的全量决定后复用 CAS 并写入完整归属。
- 新格式 State 回滚到旧原生 App 二进制不保证隔离语义；Demo 回退宿主版本需卸载重装，不宣称旧 SDK 理解新增归属字段。
- 冷启动未注册用户时为匿名，磁盘旧 gray 不可加载。先注册同一用户可继续离线使用此前验证过的 gray；离线无法实时感知服务端移出白名单，下一次成功检查才执行撤销。

## 8. 服务端数据和事务边界

新增 `OtaReleaseCounter(env, hostApp, lynxAppId, nextSequence)`，以及 `OtaSelectionState(env, hostApp, lynxAppId, policyRevision, platformOverrides)`；platformOverrides 显式表达普通选择、embedded、指定回滚目标，不复用未定义的 status 含义。

Release 另新增 versionCodeRange 与 platformVersionCodeRanges 的持久化 JSON 字段，契约类型使用十进制字符串上下界；lynxSdkRange 复用。读取时按本次请求平台计算有效范围再输出，不能在写入多平台 Release 时提前压缩为第一个平台的范围。有效范围、selection 元数据及 lastDecision 要同步保存到客户端，支持离线兼容校验。

Publish / rollback / rule change / fallback 在同一 scope 锁及数据库事务内更新 Release、规则、控制状态与 revision。查询使用一致性快照，版本集合与 revision 不能来自不同事务。数据库索引覆盖 scope/status/sequence 及规则 scope/status；对同一 scope 的并发更新按计数器行串行化。

回滚选择优先于普通排序：指定正式全量目标或 embedded；如果目标曾是灰度而要向全体用户回滚，管理端需显式将其转为全量，不能悄悄扩大用户范围。后续明确全量发布可清除对应平台回滚锁定，恢复最高版本选择；仅创建灰度规则不能清除锁定。显式 fallback 开关仍优先，只有关闭开关才恢复远程选择。

既有灰度规则禁用必须生效。发布失败（规则不存在、scope 不符、平台不符）不得提前把 Release 改为 ACTIVE。规则取消绑定后，历史 GRAY 发布不会落入正式候选集合。

## 9. 涉及仓库和文件

| 仓库 | 修改/新增路径 | 责任 |
|---|---|---|
| LynxContracts | packages/shared/src/index.ts、index.test.ts、目标 package changeset | userId/versioncode/lynxSdkVersion 请求、VersionCodeRange、平台范围、selection、序号/修订、harmony 枚举 |
| LynxOtaServer | src/modules/release/schema.ts、policy/schema.ts、policy/controller.ts | 在现有 latest 中校验三个新参数，保持成功响应形态 |
| LynxOtaServer | 新增 src/modules/policy/release-selector.ts、release-selector.test.ts | 统一选择纯函数及边界测试 |
| LynxOtaServer | release/service.ts、rule/service.ts、rollback/service.ts、policy/service.ts | 发布/规则/回滚/强制回退使用统一决策 |
| LynxOtaServer | prisma/schema.prisma、迁移、storage/contracts.ts、storage/prisma.ts、release/repository.ts、rule/repository.ts、bootstrap/db.ts | 序号、修订、原子事务及内存仓储一致性 |
| LynxOtaServer | package.json、lockfile、src/app.test.ts、policy/controller.ts | 明确 contracts 版本、HTTP/ETag/集成测试 |
| LynxOtaServer | release/repository.ts、storage/prisma.ts、metrics/controller.ts、alerts/service.ts、各 platform 枚举 | Harmony 创建/发布/查清单/Manifest/持久化/指标链不再被过滤或误归 Android |
| Client Android | LynxRouter.kt、LynxOtaConfig.kt、LynxOtaRuntime.kt、OtaApiClient.kt、OtaModels.kt、OtaSdk.kt、ContentAddressedOtaStore.kt、ActivityBundleRuntime.kt、LynxTabFragment.kt | 注册、协议、归属、失效与 Tab |
| Client iOS | LynxRouter.swift、OTA/LynxOtaRuntime.swift、OtaIOSSDK 的 Models.swift/OtaHTTP.swift/OtaSDK.swift/ContentAddressedOtaStore.swift、LynxShell.swift | 同义实现与已有 Tab reload 路径 |
| Client Harmony | routing/LynxRouter.ets、ota/OtaModels.ets/OtaApiClient.ets/LynxOtaRuntime.ets/ContentAddressedOtaStore.ets、pages/LynxTabContainer.ets | 同义实现，无 candidate |
| Client fixtures/docs | scripts/ota-store-v3/local-server.mjs、playground/scripts/generate-ota-store-v3-fixture.mjs、三端 Demo、OTA_SERVER_API_CONTRACT.md、MODULE_INTEGRATION.md、README.md | 灰度验证与宿主调用示例 |

平台 native 源码路径以前述现有 Module 为根，详细实施任务见关联执行计划。业务 Capacitor Module 不参与本次修改。服务端以独立仓为准，不再修改旧 vibecoding 副本；共享契约按该仓实际发布流程更新，不能假设修改另一个仓的源码会自动进入 Server 依赖。

## 10. 验收标准与交付

执行顺序冻结为 **Server 与其 Contracts 前置 → Server 自动测试与 HTTP 合约通过 → 再动客户端参数与 Router/Store → iOS → Android → Harmony**。Server 阶段以工作区独立仓的真实 createApp/数据库测试为依据，不用客户端 fake server 代替。后台 UI 不作为 Server 阶段阻塞：先通过已扩展发布 API 保存范围并回读；需要表单入口时另同步对应管理端，不把数据库字段存在视为 UI 已接通。

- 用户白名单只影响可选灰度集合；全量 V7 必须压过灰度 V6，灰度 V8 仅对白名单用户胜过全量 V7。
- 单 App 100 Bundle 仅 bundle-050 改变时，下载 1 个、未变化文件复制 0 次；普通背景更新保留旧 Tab 实例。
- 注册 A → B、退出、匿名冷启动、A 慢请求在 B 后返回、candidate 迟到健康回调、同包 gray→full 均有自动断言。
- 服务端全量/定向选择一致；versioncode 上下界、SDK 上下界、组合不兼容、多平台独立范围、Harmony 持久化、旧请求受约束排除、禁用规则、历史灰度、rollback V10→V5 和强制 embedded 全覆盖。
- iOS → Android → Harmony 分阶段运行相同 fixture，每端输出带截图、请求计数、Store 元数据及实际加载身份的 HTML 报告。
- 方案状态与测试状态分开。当前没有执行灰度功能测试；原有 Store v3 测试通过记录不能当作本次通过。

执行计划：[逐任务实施与验收计划](superpowers/plans/2026-09-05-ota-user-gray-latest.md)。
