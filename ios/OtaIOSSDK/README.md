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
2. 如果 SHA 一致且本地文件存在，直接复用原 `localFilePath`。
3. 如果 SHA 不一致或本地文件不存在，才下载 manifest 中的 `bundleUrl`。
4. 只对新下载的 bundle 做文件 SHA256 校验；复用 bundle 只做文件存在性检查。

因此发布侧可以保持“全量 manifest”，客户端实际网络下载仍然是“按 SHA 增量下载”。这样既能保证 release 是完整快照，也能避免 bundle 很多时重复下载未变化文件。

## 和主工程集成时的边界

当前 SDK 已经能直接集成到主工程里跑 OTA 状态机，但要真正“页面打开即可用”，主工程还需要自己提供：

1. Lynx / Sparkling 容器层
2. embedded bundle 的打包与随包分发
3. `pageId -> 容器打开` 的业务路由

也就是说：

- **OTA 能力**：现在 SDK 已经负责
- **页面容器承载**：主工程宿主负责

## 当前状态

这个 SDK 已经可以作为主工程的 OTA 核心能力接入。
如果要做到“接进主工程后页面直接打开”，还差 Lynx / Sparkling 宿主接入那最后一层。
