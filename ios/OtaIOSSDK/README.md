# iOS OTA SDK

`ios/OtaIOSSDK` 是本仓库 iOS 宿主级 OTA runtime 的 SwiftPM 单测边界；业务工程通过
`LynxShellKit.podspec` 一起编译，不需要再单独接一个 OTA Pod。

## PlatformKit 边界

- 这是 native host SDK，不是单个 Sparkling Method 包。
- 它负责 OTA 下载、缓存、校验、激活、回滚和本地 bundle URL 路由。
- `LynxPlatformKit/methods/ota` 后续只负责 Lynx 页面侧 bridge method；真实下载和缓存由本 SDK 承担。
- 根脚本 `pnpm ios:sdk:build` 已指向本目录。

## 发布

- 发布 SwiftPM / SPM package，入口为 `Package.swift`。
- CocoaPods 业务入口为 `../LynxShellKit.podspec`，OTA 源码作为同一个 Router Module 的内部实现。
- 版本说明必须包含 Sparkling SDK 兼容范围、Lynx engine 兼容范围和 OTA API contract 版本。

它的目标不是只做一个底层下载器，而是让主工程按“接一个 Router Module”的方式使用完整 OTA
Store、容器和路由链路。

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
- Store v3：完整 Manifest + App ID 作用域 CAS Object，按 SHA 复用任意历史对象
- 有界保留 current / previous / candidate
- 页面级 Release lease 与延迟回收
- 导航 session release snapshot，保证同一页面栈不混用不同版本
- 冷启动 orphan / staging 清理
- 下载前容量预检
- 只读磁盘诊断快照

### Canonical 本地 Store v3 布局

下载版本与 Android 保持同一目标模型：Bundle bytes 按 SHA-256 存入 App ID 作用域的 CAS，完整
Manifest 只保存逻辑路径和 Object 引用，State 只保存 current/previous/candidate 指针。未变化的
Bundle 不复制到新 Release。

```text
<storageDirectory>/
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
