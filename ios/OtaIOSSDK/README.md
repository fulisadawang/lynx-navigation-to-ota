# iOS OTA SDK

`ios/OtaIOSSDK` 是本仓库 iOS 宿主级 OTA runtime 的 SwiftPM 单测边界；业务工程通过
`LynxShellKit.podspec` 一起编译，不需要再单独接一个 OTA Pod。

## Core 与宿主边界

- Core 负责 OTA HTTP、下载、校验、选择元数据、激活、回滚和本地 Bundle lease。
- Core 使用 Foundation、CryptoKit 和 Swift Concurrency，不直接导入 UIKit、SwiftUI 或 Lynx；
  UIViewController、Native Tab、登录事件与导航 session 由 `LynxShellKit` 接线。
- 事务链为 `OtaSDK → ReleaseTransaction → OtaReleaseStoreBackend → ContentAddressedOtaStore`。
- 原生 versionCode 与可信 Lynx Runtime 版本由 Shell 提供；Core 不读取 UI 状态来推断身份或版本。

## 构建与集成

- SwiftPM 入口为 `Package.swift`，声明 iOS 15 / macOS 14，主要用于独立 Core 编译与单测。
- CocoaPods 业务入口为 `../LynxShellKit.podspec`，OTA 源码作为同一个 Router Module 的内部实现。
- 当前 Pod 声明 iOS 13 / Swift 5；业务导入 `LynxShellKit`，无需再添加独立 OTA Pod。
- 下文 `import OtaIOSSDK` 用于 SwiftPM 示例；版本发布应分别记录 Core、Pod 构建和设备运行证据。

它的目标不是只做一个底层下载器，而是让主工程按“接一个 Router Module”的方式使用完整 OTA
Store、容器和路由链路。

## 当前能力

- 检查更新
- 按 `hostApp + lynxAppId + platform` 拉取完整 bundle-list，支持身份与原生版本上下文
- 下载 bundle
- SHA256 校验
- 按 `bundlePath + bundleSha256` 增量下载：manifest 仍是全量清单，但本地已存在且 SHA 一致的 bundle 会直接复用
- staged 激活
- 回滚到上一个版本或 embedded
- 获取当前版本
- 获取当前 bundle 本地文件地址
- 按 `lynxAppId` 物理隔离 Release
- Store v3：完整 Manifest + App ID 作用域 CAS Object，按 SHA 复用仍在磁盘的历史对象，不无限保留所有历史
- 有界保留 current / previous / candidate
- 页面级 Release lease 与延迟回收
- 导航 session release snapshot，保证同一页面栈不混用不同版本
- 冷启动 orphan / staging 清理
- 下载前容量预检
- 只读磁盘诊断快照
- 同步注册/清除用户、epoch 屏障、full/gray 元数据和持久化 lastDecision
- 全量批次先独立提交各 App 决定，再下载；部分失败保留成功结果并抛出聚合错误

### Canonical 本地 Store v3 布局

下载版本与 Android 保持同一目标模型：Bundle bytes 按 SHA-256 存入 App ID 作用域的 CAS，完整
Manifest 只保存逻辑路径和 Object 引用，State 只保存 current/previous/candidate 指针。未变化的
Bundle 不复制到新 Release。

```text
<storageDirectory>/
├── selection-salt
└── apps/<lynxAppId>/
    ├── state.json
    ├── embedded.json
    ├── manifests/<manifestSha256>.json
    ├── objects/<sha256-prefix>/<sha256>.lynx.bundle
    └── transactions/<transactionId>/
        ├── transaction.json
        └── *.part
```

`state.json` 和本地 Manifest 使用 Store schema v3。Store 不再读取或迁移旧 `current-release*.json`、
顶层 `releases`、`states` 或 v2 Release 目录；Demo 通过卸载重装获得空沙盒。两个 App ID 即使收到
相同 `releaseId` 和 SHA，也会写入不同的 `apps/<lynxAppId>/objects`，互不覆盖。

embedded baseline 的 Bundle bytes 始终留在 App Bundle。`embedded.json` 只保存逻辑描述，
不会在 Application Support 再复制一份 baseline。

### 保留、lease 与清理

- 正常激活后保留当前 Release 与直接前驱 previous；连续 V1...V10 后只剩 V9/V10。
- candidate 模式最多额外保留一个 candidate；新的 candidate 会替换旧候选。
- `OtaBundleLease` 把远程 Release 的生命周期绑定到正在展示它的 UIViewController/Native Tab。
  删除或激活新版本只会先移除指针，被 lease 引用的目录等最后一个 lease 关闭后再删除。
- 冷启动维护从 current、previous、candidate、活体 lease 和 transaction roots 重建引用集合，
  只删除可确认无引用的 Manifest/Object；状态损坏时保守保留。
- staging 前先 prune，再按目标 Bundle 大小、元数据余量和安全保留空间做容量预检；不足时抛出
  `OtaSDKError.insufficientStorage`，旧 current 保持不变。
- 回滚到超出保留集合的版本时，若旧050已被GC，可以补下缺失1个并复用其余99个；完整Manifest不变成patch链，也不以永久保留历史换取零下载。

### 只读诊断

`OtaSDK.storageSnapshot()` 返回真实 root、各 App 的 current/previous/candidate、Release 角色、
lease、文件树与字节数。该 API 不创建目录、不清理文件、不计算 SHA，也不触发网络，可直接用于
Debug Inspector 或问题上报。

## 用户与原生版本上下文

### 配置及真实版本来源

`OtaSDKConfiguration.versionCode` 的默认值是 `nil`：这保留低层旧模式，**不会自动读取
CFBundleVersion**。启用新选择语义时必须提供合法 `versionCode`、`lynxSdkVersion`，并明确选择
`.v3`；低层 `storeVersion` 的兼容默认值仍为 `.v2`。

Shell 的配置入口以显式 `versionCode` 优先，否则验证宿主构建号；纯整数 CFBundleVersion 可直接使用，
分段值如 `1.2.3` 必须显式提供整数覆盖。`buildNumber` 继续保留原有上报语义，不能删掉小数点来伪造 versioncode。

Lynx SDK 版本由 Shell 从**与实际 Lynx 依赖一起打包的可信 metadata**解析：

- `LynxResources.bundle` 的 `CFBundleShortVersionString`，且 bundle identifier 必须为
  `org.cocoapods.LynxResources`。
- 若存在实际 Lynx framework metadata，只接受 `org.cocoapods.Lynx`；多个可信来源必须一致。
- 显式 `lynxSDKVersion` 也必须与解析出的实际版本相同。metadata 缺失或冲突时配置失败。

这避免某些源码 Pod 缺少版本宏时 `LynxVersion` 方法误报 `1.4.0`，也不会将链接 build number 或写死
`4.0.0` 当作实际 Runtime 版本。读取及校验逻辑位于 Shell 的 `LynxOtaConfiguration` /
`LynxSDKVersionResolver`，Core 只接收其结果，不因此依赖 UIKit 或 Lynx。

以下是直接调用 Core 的 SwiftPM 示例。URL 必须是宿主已验证的 HTTPS URL；`clientToken` 来自宿主安全配置，
示例不包含凭证。`verifiedLynxSDKVersion` 必须由上述可信来源提供。

```swift
import Foundation
import OtaIOSSDK

func makeContextualSDK(
    apiBaseURL: URL,
    clientToken: String,
    environment: OtaEnvironment,
    appVersion: String,
    nativeBuild: String,
    explicitVersionCode: String? = nil,
    verifiedLynxSDKVersion: String,
    initialUserId: String?,
    storageDirectory: URL
) throws -> OtaSDK {
    let code = try OtaUserContext.normalizeVersionCode(explicitVersionCode ?? nativeBuild)
    let runtimeVersion = try OtaUserContext.normalizeLynxSdkVersion(verifiedLynxSDKVersion)
    let user = try OtaUserContext.normalizeUserId(initialUserId)
    let configuration = OtaSDKConfiguration(
        apiBaseURL: apiBaseURL,
        app: .capp,
        lynxAppId: "10000001",
        environment: environment,
        platform: .ios,
        appVersion: appVersion,
        buildNumber: nativeBuild,
        versionCode: code,
        userId: user,
        lynxSdkVersion: runtimeVersion,
        otaClientToken: clientToken,
        storageDirectory: storageDirectory,
        candidateActivationEnabled: true,
        storeVersion: .v3
    )
    return OtaSDK(configuration: configuration)
}
```

embedded 仍通过 `try await sdk.initializeEmbeddedRelease(embeddedRelease)` 注册实际随包资源。
如果发布使用 `nativeProtocolVersionRange`，配置还应提供宿主的 `nativeProtocolVersion`。

规范化与 Server 保持一致：userId 先拒绝原始输入中的 C0/C1 控制字符，再 trim；空白视为匿名，保留大小写、
前导零和原始 UTF-8 标识，最多 256 UTF-8 字节。versioncode 先 trim，再验证为 `1...9223372036854775807`
的十进制整数；SDK 稳定版本先 trim，接受 1–3 个数字段并补齐三段，拒绝预发布标签。

### 同步注册与异步同步

`registerUserId(_:)` 是同步、nonisolated、可抛错方法：改变身份返回 true；规范化后相同返回 false，epoch 不变。
`registerUserId(nil)` 等价于清除用户。注册不联网、不等待大量文件 I/O；它立即使旧身份操作失效。

宿主应串行处理登录/退出事件，例如使用 MainActor，并把注册时捕获的 epoch 贯穿后续操作。Core 不自动触发
网络请求；Shell 负责合并启动/身份切换同步、使旧 gate/session 失效并安排 Tab 重建。

```swift
@MainActor
func registerSDKIdentity(_ sdk: OtaSDK, userId: String?) throws -> UInt64? {
    guard try sdk.registerUserId(userId) else { return nil }
    return sdk.userIdentityEpoch
}

func reconcileSDKIdentity(_ sdk: OtaSDK, expectedEpoch: UInt64) async throws {
    try await sdk.withUserIdentity(expectedIdentityEpoch: expectedEpoch) {
        try await sdk.reconcileUserContext()
    }
}
```

若 install 前已恢复登录态，可以通过配置注入初始 userId，随后仅执行一次启动全量同步。
身份切换后先 reconcile，再同步 latest；即使同步部分失败，宿主也应从已经提交的 State 重读本地版本。

### latest wire 与本地选择记录

定向调用为 `try await sdk.updateToLatestBundleList(lynxAppId: appId)`；
全量调用为 `try await sdk.updateToLatestBundleLists()`。请求字段固定为：

```http
GET /api/ota/v1/releases/latest-bundle-list?env=TEST&hostApp=capp&lynxAppId=10000001&platform=ios&versioncode=800&lynxSdkVersion=4.0.0
```

有用户时才附加 `userId`，全量请求省略 `lynxAppId`。上述数字仅展示 wire 形状，实际值来自宿主配置。
新模式解码全量 `bundleLists/directives`，或定向 selected/decision；缺少 selection 元数据会失败，不静默降级为 full。
Server 在用户资格和兼容过滤后比较 releaseSequence，因此 full7 胜 gray6；有资格用户的 gray8 可以胜 full7。

| 字段 | SDK 用途 |
|---|---|
| `releaseSequence` | 服务端分配的发布顺序，十进制字符串；不能据此拒绝服务端回滚 |
| `selection.kind` / `ruleId` | 记录 full/gray 及灰度诊断来源 |
| `policyRevision` | 相同 clientContextKey 下拒绝更旧决定；更高 revision 可以选择更低 releaseSequence |
| `versionCodeRange` / `lynxSdkRange` | 本地读取也检查的兼容范围，上下界包含 |
| `audienceKey` / `clientContextKey` | 身份、平台和原生/Runtime 上下文摘要，不存原始 userId |

State 仍是 schema v3，新增 `selectionSchemaVersion`，current/previous/candidate 引用保存
`OtaStoredSelection`。`lastDecision` 保存 audienceKey、clientContextKey、policyRevision、action、目标 releaseId
和 reason，与 State 原子提交。合法批次先完成各 App 决定的独立提交尝试，再开始下载；提交前仍检查原操作 epoch。

`use_embedded` / `no_compatible_release` 会阻断旧 remote 的新入口，并在冷读取时保持。网络错误没有产生新决定时，
只保留当前身份仍适用的本地版本。旧 v3 中缺少 selection 的 remote 在新模式下暂不可选，等待 Server 确认；
确认后仍复用 CAS。gray→full 同 release 的 metadata 更新不会被 already-active 分支跳过，也不需要再次下载同一 bytes。
`selection-salt` 是安装级随机盐；不建立用户目录，也不为每个历史账号保存独立 Bundle 副本。

### 全量部分失败的处理

`updateToLatestBundleLists()` 仍为 throws 接口；任何 App 失败都抛出 `OtaHostBundleListSyncError`。
其 `partialResult.results` 只含已完成 App，`failures` 按 App ID 保存失败阶段 `.decision` / `.update` 和 `cause`。
协议整体非法时不先提交其中部分决定；身份失效或取消时立即停止。

以下 `HostSyncOutcome` 是宿主示例包装类型，不是额外的 SDK API。它明确保留“部分完成但整批失败”的区别：

```swift
struct HostSyncOutcome: Sendable {
    let completed: OtaHostBundleListSyncResult
    let failures: [String: OtaAppBundleListSyncFailure]
    var allSucceeded: Bool { failures.isEmpty }
}

func synchronizeSDKHost(_ sdk: OtaSDK, expectedEpoch: UInt64) async throws -> HostSyncOutcome {
    try await sdk.withUserIdentity(expectedIdentityEpoch: expectedEpoch) {
        do {
            let result = try await sdk.updateToLatestBundleLists()
            return HostSyncOutcome(completed: result, failures: [:])
        } catch let error as OtaHostBundleListSyncError {
            return HostSyncOutcome(completed: error.partialResult, failures: error.failures)
        }
    }
}
```

宿主只对 `completed.results` 中的 App 更新同步门控；`allSucceeded == false` 不能当作全量成功。
无论结果真假，都应在有效身份上下文内从已提交的 State 重读 current/candidate，让其他 App 已生效的更新或撤销可见。
普通错误与 staleIdentity 继续向外抛出，不能用空列表吞掉。默认批次错误描述及新检查上报诊断已脱敏；
`cause` 仍保留原始错误，可能含请求 body/URL，不应直接输出到用户日志。

### lease 与候选回调

本地 cache-only 路径可调用 `acquireCurrentBundleLease`，无需等待宿主为整段网络事务持有的 gate。
Store actor 在同一执行段解析引用并登记 lease，SDK/wrapper 在返回前复核身份；磁盘校验或 Store 提交仍可能短暂排队。

```swift
func acquireSDKLease(
    _ sdk: OtaSDK,
    lynxAppId: String,
    bundleName: String,
    preparedEpoch: UInt64
) async throws -> OtaBundleLease? {
    try await sdk.withUserIdentity(expectedIdentityEpoch: preparedEpoch) {
        try await sdk.acquireCurrentBundleLease(lynxAppId: lynxAppId, bundleName: bundleName)
    }
}

func closeSDKLease(_ lease: OtaBundleLease) async {
    await lease.close()
}
```

宿主应持有成功返回的 lease 直到页面销毁，并显式 await close。若 wrapper 在最终 epoch 校验时拒绝 lease 结果，
它会先 await close 再抛错，覆盖直接返回和 Optional 返回；宿主自己的最后一次 epoch 检查失败时也应关闭已拿到的 lease。
Core 不持有或操作 UIViewController。

开启 candidate 模式后，加载候选前调用 `beginCandidateTrial(lynxAppId:)`，再获取 candidate lease。
宿主保存 prepared 时的 releaseId 和 epoch；首屏健康确认/失败回调必须继续使用这两个原始值：

```swift
func confirmSDKCandidate(
    _ sdk: OtaSDK,
    lynxAppId: String,
    preparedReleaseId: String,
    preparedEpoch: UInt64
) async throws -> OtaInstalledRelease {
    try await sdk.withUserIdentity(expectedIdentityEpoch: preparedEpoch) {
        try await sdk.confirmCandidateHealthy(
            lynxAppId: lynxAppId,
            expectedReleaseId: preparedReleaseId,
            expectedIdentityEpoch: preparedEpoch
        )
    }
}

func discardSDKCandidate(
    _ sdk: OtaSDK,
    lynxAppId: String,
    preparedReleaseId: String,
    preparedEpoch: UInt64
) async throws {
    try await sdk.withUserIdentity(expectedIdentityEpoch: preparedEpoch) {
        try await sdk.discardCandidate(
            lynxAppId: lynxAppId,
            expectedReleaseId: preparedReleaseId,
            expectedIdentityEpoch: preparedEpoch
        )
    }
}
```

`withUserIdentity` 保留外层 TaskLocal，SDK 内部不能重新捕获新身份覆盖旧身份。捕获到
`staleIdentity` / `staleCandidate` / `staleDecision` 后，应结束旧操作，不再以“当前 epoch”重试旧 rollback/delete。
Swift TaskLocal 不是跨进程凭证；新建 detached task 或未来 UI 回调时，仍须显式携带 prepared epoch 重新进入 wrapper。

### 异常边界与兼容接口

- `invalidUserId`、`invalidVersionCode`、`invalidSDKVersion` 表示输入不满足协议；宿主在构造 Core 前验证配置。
- `missingSelectionMetadata` / `invalidSelectionMetadata` 不会将未知 remote 视为 full。
- `incompatibleRelease`、缺少本地 Bundle、网络或 SHA/size 失败不等于版本选择成功；使用仍符合当前身份和范围的本地回退。
- `requiresStoreV3` 表示在旧 Store 上尝试启用新选择模式。
- URL 配置必须满足 HTTPS 边界；TEST loopback HTTP 必须显式启用 `allowLocalHTTPForTest`。SDK 初始化中的 URL
  precondition 不是可 catch 的网络错误，宿主需提前验证。配置无效时仍可由 Shell 的独立 embedded registry 提供本地页面。
- 新检查失败/candidate 成功会报告 check-result；下载、激活和页面报告使用操作捕获的身份。原始 userId 只进入协议专用字段，
  不写 State 或错误诊断文本；不要把携带用户 query 的完整 URL 写入日志。
- 旧 `LynxHotUpdate.shared`、`syncLatestBundleList()`、`syncLatestBundleLists()`、`sync(OtaCheckRequest)` 与
  pageId 模板读取入口继续保留。新身份流程直接由 Shell 持有的 `OtaSDK` 接线；旧 façade 没有新增 registerUserId 方法。

## Bundle 下载策略

服务端每个 release 的 manifest 是完整版本快照，里面会包含当前版本应具备的所有 bundle。SDK 下载时不会盲目全量下载，而是先拿当前已安装 release 的本地 bundle 做对比：

1. 解析服务端返回的完整 Manifest，按 `bundlePath + bundleSha256` 建立完整逻辑快照。
2. 先查当前 App ID 的 CAS Object；对象存在且 SHA/size 一致时直接复用，不请求网络、不复制字节。
3. 如果 Object 缺失或校验失败，才下载 Manifest 中的 `bundleUrl`，先写 `.part`，校验通过后原子
   rename 到 CAS。
4. 完整 Manifest durable 后再原子提交 State；只有完整 release 才能成为 current。

因此发布侧可以保持“全量 manifest”，客户端实际网络下载仍然是“按 SHA 增量下载”。这样既能保证 release 是完整快照，也能避免 bundle 很多时重复下载未变化文件。

## 和主工程集成时的边界

当前 SDK 已经能直接集成到主工程里跑 OTA 状态机；通用 SDK 仍要求接入方提供：

1. Lynx / Sparkling 容器层
2. embedded bundle 的打包与随包分发
3. `pageId -> 容器打开` 的业务路由

也就是说：

- **OTA 能力**：现在 SDK 已经负责
- **页面容器承载**：主工程宿主负责

## 当前状态

这个 SDK 已经可以作为主工程的 OTA 核心能力接入。本仓库的 `LynxShellKit` 已完成
UIViewController、Native Tab、首屏健康确认、release snapshot、CAS lease 与只读 Inspector 的
宿主接线。Debug 环境还提供 `playground/scripts/generate-ota-store-v3-fixture.mjs` 生成 100 Bundle
Golden Fixture，以及本地 OTA Server 用于验证真实 URLSession/Manifest/Bundle 请求链路；业务接入
仍应在 Release 配置中保持 HTTPS。

### 本次验证与历史边界

2026-09-06 本次 Core 为 **83 tests passed**，命令为 `swift test --no-parallel`。
Shell 的最终 UI run 为4/4、19张截图，见 [iOS user-gray报告](../../docs/ios-ota-user-gray-test-report.html)；这是宿主UI证据，不把83个Core测试说成设备测试。
Core不直接依赖UIKit/Lynx，可信Runtime metadata解析仍由Shell负责。旧 [Store v3报告](../../docs/ios-ota-store-v3-test-report.html) 另列历史，不覆盖本次身份协议结论。
三端匿名内置脚本的iOS命令见 [Module接入](../../MODULE_INTEGRATION.md#三端匿名内置-baseline-下载)，必须传 `--target ios --platform ios --versioncode ... --lynx-sdk-version ...`，不传userId。
