# iOS OTA SDK

`LynxPlatformKit/sdks/ios-ota` 是 iOS 宿主级 OTA runtime 的 PlatformKit 入口。

## PlatformKit 边界

- 这是 native host SDK，不是单个 Sparkling Method 包。
- 它负责 OTA 下载、缓存、校验、激活、回滚和本地 bundle URL 路由。
- `LynxPlatformKit/methods/ota` 后续只负责 Lynx 页面侧 bridge method；真实下载和缓存由本 SDK 承担。
- 根脚本 `pnpm ios:sdk:build` 已指向本目录。

## 发布

- 发布 SwiftPM / SPM package，入口为 `Package.swift`。
- 发布 CocoaPods package，入口为 `OtaIOSSDK.podspec`。
- 版本说明必须包含 Sparkling SDK 兼容范围、Lynx engine 兼容范围和 OTA API contract 版本。

## 旧目录兼容

迁移期旧目录暂时保留为兼容参考：

```text
LynxOtaPlatform/ios/sdk
```

这是当前仓库的 iOS OTA SDK。

它的目标不是只做一个底层下载器，而是让你的主工程后面可以按“接一个 SDK”的方式直接用起来。

## 当前能力

- 检查更新
- 按 `hostApp + lynxAppId` 拉取最新全量 bundle-list
- 下载 bundle
- SHA256 校验
- 按 `bundlePath + bundleSha256` 增量下载：manifest 仍是全量清单，但本地已存在且 SHA 一致的 bundle 会直接复用
- staged 激活
- 回滚到上一个版本或 embedded
- 获取当前版本
- 获取当前 bundle 本地文件地址
- 按 `lynxAppId` 物理隔离 Release
- 有界保留 current / previous / candidate
- 页面级 Release lease 与延迟回收
- 冷启动 orphan / staging 清理
- 下载前容量预检
- 只读磁盘诊断快照

### Canonical 本地 Release 布局

下载版本与 Android 保持同一目标模型：Bundle 不把绝对文件路径写进 current state，完整 Release
自包含于固定目录，state 只保存 Release 引用。

```text
<storageDirectory>/
└── apps/<lynxAppId>/
    ├── state.json
    ├── staged.json
    ├── candidate.json
    ├── embedded.json
    ├── releases/<releaseId>/
    │   ├── release-manifest.json
    │   └── <bundlePath>
    └── .staging/<releaseId>.<transactionId>/
```

`state.json`、`staged.json` 与 `candidate.json` 使用 Store schema v2。Store 不再读取或迁移旧
`current-release*.json` / 顶层 `releases` / `states` 布局；Demo 通过卸载重装获得空沙盒。
两个 App ID 即使收到相同 `releaseId`，也会写入不同物理目录，互不覆盖。

embedded baseline 的 Bundle bytes 始终留在 App Bundle。`embedded.json` 只保存逻辑描述，
不会在 Application Support 再复制一份 baseline。

### 保留、lease 与清理

- 正常激活后保留当前 Release 与直接前驱 previous；连续 V1...V10 后只剩 V9/V10。
- candidate 模式最多额外保留一个 candidate；新的 candidate 会替换旧候选。
- `OtaBundleLease` 把远程 Release 的生命周期绑定到正在展示它的 UIViewController/Native Tab。
  删除或激活新版本只会先移除指针，被 lease 引用的目录等最后一个 lease 关闭后再删除。
- 冷启动维护只删除 schema v2 中可确认无引用的 Release 和 staging；状态损坏时保守保留。
- staging 前先 prune，再按目标 Bundle 大小、元数据余量和安全保留空间做容量预检；不足时抛出
  `OtaSDKError.insufficientStorage`，旧 current 保持不变。

### 只读诊断

`OtaSDK.storageSnapshot()` 返回真实 root、各 App 的 current/previous/candidate、Release 角色、
lease、文件树与字节数。该 API 不创建目录、不清理文件、不计算 SHA，也不触发网络，可直接用于
Debug Inspector 或问题上报。

## 推荐接法

主工程优先直接使用 `LynxHotUpdate.shared`：

```swift
import OtaIOSSDK

let configuration = OtaSDKConfiguration(
    apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
    app: .capp,
    lynxAppId: "10000000",
    environment: .test,
    appVersion: "1.0.0",
    buildNumber: "100",
    otaClientToken: "local-test-client-token"
)

let embedded = OtaInstalledRelease(
    context: OtaCurrentReleaseContext(
        env: .test,
        app: .capp,
        lynxAppId: "10000000",
        releaseId: "embedded",
        platform: .ios,
        status: .active
    ),
    installedAt: .now,
    bundles: []
)

try await LynxHotUpdate.shared.initialize(
    configuration: configuration,
    embeddedRelease: embedded
)
```

### 推荐：按最新 BundleList 更新

客户端会请求公共接口：

```http
GET /api/ota/v1/releases/latest-bundle-list?env=TEST&hostApp=capp&lynxAppId=10000000&platform=ios
```

拿到发布管理中当前 `LynxAppID` 最新的全量 bundle-list 后，SDK 会遍历其中每个 bundle，按 `bundlePath + bundleSha256` 判断本地是否可复用；只有变化或缺失的 bundle 才会下载。

```swift
let result = try await LynxHotUpdate.shared.syncLatestBundleList()
```

### 兼容：按页面策略检查

```swift
let result = try await LynxHotUpdate.shared.sync(
    OtaCheckRequest(pageId: 10000000, userId: "42")
)
```

### 读取当前模板地址

```swift
let templateURL = await LynxHotUpdate.shared.currentTemplateURL(pageId: 10000000)
```

这个 URL 就是你后面接 Lynx / Sparkling 宿主时真正要交给容器层的本地 bundle 文件地址。

## Bundle 下载策略

服务端每个 release 的 manifest 是完整版本快照，里面会包含当前版本应具备的所有 bundle。SDK 下载时不会盲目全量下载，而是先拿当前已安装 release 的本地 bundle 做对比：

1. 用 `bundlePath + bundleSha256` 查找本地已安装 bundle。
2. 如果 SHA 一致且本地文件存在，复制到新 Release 的 staging 目录，并重新校验 SHA；不会把旧
   Release 的绝对 `localFilePath` 持久化到新 current。
3. 如果 SHA 不一致或本地文件不存在，才下载 manifest 中的 `bundleUrl`。
4. 新下载和从旧 Release 复用的 Bundle 都在发布前校验，只有完整 Release 才能提交 current。

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
UIViewController、Native Tab、首屏健康确认、lease 与只读 Inspector 的宿主接线，可作为业务
工程集成参考。
