# LynxShell Android / iOS Module 接入

## 目标

Android 与 iOS 都采用“可复用 Module + Sample App”结构：

```text
业务 App
  -> LynxShell 公开 Interface
  -> Runtime / Container / Router / Transition / NativeModules
  -> Lynx 4.0 + Service + XElement
```

Module 内保留当前全部手写 `NativeModules.LynxShellModule`、高级导航、页面级原生转场、
资源 Provider 和 XElement。Sample 只演示初始化、绑定宿主导航器、打开 Bundle 以及
“回业务主页”接线。不使用 `sparkling-method`、`spkPipe`、autolink 或 codegen。

## Android

### 目录与依赖

```text
android/
├── lynx-shell/       Android Library，产物为 AAR
│   ├── build.gradle.kts
│   ├── consumer-rules.pro
│   └── src/main/
└── app/              可运行 Sample，只保留 Launcher 与业务宿主接线
```

同一个 Gradle 工程直接引用：

```kotlin
dependencies {
    implementation(project(":lynx-shell"))
}
```

其他仓库可以复制 `lynx-shell` Module，或者先发布到本机 Maven：

```bash
# 在包含该 Module 的 Android 工程根目录执行；使用该工程自己的 Wrapper。
./gradlew :lynx-shell:publishToMavenLocal
```

当前源码包的 `android/` 目录没有单独提交 Wrapper，可直接从 Android Studio 执行同名
Task；复制到业务工程后应使用业务工程自己的 Wrapper。发布坐标：

```kotlin
repositories {
    mavenLocal()
    google()
    mavenCentral()
}

dependencies {
    implementation("com.example.lynx:lynx-shell-android:1.0.0")
}
```

远程 Bundle 不配置 Host 白名单；Android/iOS/HarmonyOS 统一按 HTTPS、响应码、重定向协议和 20 MB 体积上限校验。

### Application 初始化

```kotlin
class MyApplication : Application() {
    override fun onCreate() {
        super.onCreate()

        // 三端统一入口；Android 的实际承载是 Activity-first。
        // 内部初始化有幂等保护，必须早于首个 LynxView。
        // Router 内置 OTA 时直接传 LynxOtaConfig；不需要额外引入 OTA JAR。
        LynxRouter.install(this, LynxOtaConfig(...))

        // Lynx 页面要求“返回整个 App 主页面”时，由业务决定实际 Tab/Activity。
        LynxShell.installAppHomeHandler(
            AppHomeHandler { activity, optionsJson ->
                activity.startActivity(
                    Intent(activity, MainTabActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                )
                true
            }
        )
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        LynxShell.onTrimMemory(level)
    }
}
```

如果一个 Lynx session 中间会插入业务原生 Activity，再按业务 Router 注入
`SessionExitHandler`；纯连续 Lynx Activity 栈不需要。

### 原生打开 Lynx

最简字符串入口与页面侧 NativeModules 共用路由协议：

```kotlin
val result = LynxRouter.open(
    context = activity,
    bundle = "assets://bundles/main.lynx.bundle",
    params = mapOf("from" to "home"),
    options = mapOf("fullscreen" to true, "showToolbar" to false),
)
```

也可以显式构造 `LynxPageRequest`：

```kotlin
LynxShell.open(
    activity,
    LynxPageRequest(
        bundleUrl = "https://cdn.example.com/product.lynx.bundle",
        routeKey = "product-10001",
        fullscreen = true,
        showToolbar = false,
    ),
)
```

Activity-first 的 `open` 不要求预注册 routeId；Bundle 名称或 HTTPS 地址本身就是资源定位。
`LynxRouter.openScheme(activity, "hybrid://lynxview_page?bundle=pay.lynx.bundle")` 与
直接传 Bundle 共用同一套解析和参数协议。

### Activity-first OTA

OTA 页面只传逻辑身份，不传本地绝对路径，也不需要维护 route registry：

```kotlin
LynxRouter.open(
    context = activity,
    lynxAppId = "10000001",
    bundleName = "pay.lynx.bundle",
    params = mapOf("orderNo" to "A1001"),
)
```

`LynxShellActivity` 在本地没有可用 Bundle 时才显示原生 Loading，等待
`ActivityBundleRuntime.prepare(appId, bundleName)` 完成下载、校验和激活；如果本地有合法旧
版本，会先打开旧版本，再由适配器在后台刷新当前 appId。内置 OTA 默认按 appId 做 30 分钟
页面刷新门控；缺包或 SHA 错误时会绕过门控立即修复。适配器可以覆盖生命周期钩子：

```kotlin
class MyActivityBundleRuntime(...) : ActivityBundleRuntime {
    override fun onApplicationStarted() {
        backgroundExecutor.execute { otaSdk.syncLatestBundleLists() } // 全量 appId
    }

    override fun onApplicationForeground() {
        backgroundExecutor.execute { otaSdk.syncLatestBundleLists() } // 全量 appId
    }
}

// Application 从后台回到前台时调用一次
LynxRouter.onApplicationForeground()

// Application/进程确认进入后台时调用一次
LynxRouter.onApplicationBackground()
```

页面缺包时，适配器内部应调用 `syncLatestBundleList(appId)`，只同步当前页面所属
appId；不能再次触发宿主全量同步。首屏失败时按 appId 回滚一次后重试。
当前统一工程的 Android Router AAR 已内置 OTA SDK 和默认 `LynxOtaRuntime`，业务只需要
配置 `LynxOtaConfig`。`ActivityBundleRuntime` 仍然作为可选扩展口保留，适合已有 OTA
实现或需要替换网络层的宿主；不是三方接入的必选步骤。实现位置是本仓库的
`android/lynx-shell`。

Sample 的 Bundle 放在 `android/app/src/main/assets/bundles`。Library 不携带业务 Bundle；
接入方应把自己的普通 Bundle 放进最终 App assets；OTA Bundle 由 OTA SDK 存入 App 私有
目录，不放进 `assets/ota`。

Android 诊断页或 Lynx 页面需要主动释放 OTA 磁盘空间时，可直接调用：

```kotlin
LynxRouter.deleteOtaBundles("10000001") { success, message -> /* 指定 appId */ }
LynxRouter.deleteAllOtaBundles { success, message -> /* 全部 appId */ }
```

Lynx 页面侧对应 `NativeModules.LynxShellModule.deleteOtaBundles` /
`deleteAllOtaBundles`。两者都是永久删除 `files/lynx-ota-store` 中的下载内容，不生成
隐藏备份目录；`embedded` 描述和 APK assets 保留，回调必须检查 `code === 0`。

## iOS

### 目录与显式 Pod 引用

```text
ios/
├── LynxShellKit/          CocoaPods Module 源码
├── LynxShellKit.podspec   Lynx 4.0、Service、全量 XElement 依赖
└── LynxShellSample/       可运行 App，仅保留 App/Scene/Launcher/Bundles
```

当前 Sample 的 Podfile 只有一条直接业务依赖：

```ruby
target 'LynxShell' do
  pod 'LynxShellKit', :path => '.'
end
```

其他工程使用相对或绝对路径显式引用：

```ruby
target 'MyApp' do
  use_frameworks! :linkage => :static
  pod 'LynxShellKit', :path => '../lynx-navigation-to-ota/ios'
end
```

然后执行：

```bash
pod install
```

`LynxShellKit.podspec` 自己携带 Lynx、PrimJS、LynxService、SDWebImage 与 XElement
10 个 subspec。业务 App 不再逐项复制这些 Pod 声明。由于 XElement AutoRegistry 位于
Objective-C 静态 Framework，最终 App Target 仍需：

```text
OTHER_LDFLAGS = $(inherited) -ObjC
```

### App 与导航器初始化

```swift
import LynxShellKit

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 可选：如果在 Scene 中调用 LynxRouter.install，这里可以省略 bootstrap。
        LynxShell.bootstrap()
        return true
    }
}
```

在业务 Scene/Coordinator 创建真实导航器后绑定：

```swift
let navigationController = mainTabNavigationController
// iOS Native Page Stack = UINavigationController + LynxContainerViewController。
LynxRouter.install(to: navigationController)

LynxShell.installAppHomeHandler { navigationController, options in
    tabBarController.selectedIndex = 0
    navigationController.popToRootViewController(animated: false)
    return true
}
```

如果业务使用 OTA，初始化时一次性把配置传给 Router；令牌由业务安全配置提供：

```swift
let ota = LynxOtaConfiguration(
    apiBaseURL: URL(string: "https://ota.example.com")!,
    hostApp: "capp",
    defaultLynxAppId: "10000001",
    environment: "PROD",
    clientToken: secureRuntimeToken
)
try LynxRouter.install(to: navigationController, otaConfiguration: ota)

// App 启动和每次回前台都可调用；重叠同步会由 Runtime 合并。
LynxRouter.onApplicationForeground()

// Scene 进入后台时调用；页面 VC hidden 与 App background 是两个独立状态。
LynxRouter.onApplicationBackground()
```

### 原生打开 Lynx

```swift
let result = try LynxRouter.open(
    bundle: "main.lynx.bundle",
    params: ["from": "home"],
    options: [
        "title": "首页",
        "fullscreen": true,
        "showNavigationBar": false,
    ]
)

// HTTPS Bundle 和 Sparkling 兼容 Scheme 使用同一个入口。
_ = try LynxRouter.openScheme(
    "hybrid://lynxview_page?bundle=pay.lynx.bundle&title=支付",
    params: ["orderId": "10001"]
)

_ = LynxRouter.pop()
_ = LynxRouter.popTo("main.lynx.bundle")
_ = LynxRouter.closeAll()
_ = try LynxRouter.reLaunch(
    bundle: "login.lynx.bundle",
    params: ["from": "expired-session"]
)

// OTA 页面只传 appId + bundleName + params。
_ = try LynxRouter.open(
    lynxAppId: "10000001",
    bundleName: "pay.lynx.bundle",
    params: ["orderId": "10001"],
    options: ["title": "支付"]
)

try await LynxRouter.deleteOtaBundles(lynxAppId: "10000001")
try await LynxRouter.deleteAllOtaBundles()
```

OTA 命中合法 `current` 时立即打开，并按 appId 做 30 分钟后台检查；缺包或校验失败会显示
原生 Loading，等待定向下载、size/SHA 校验、staging 和原子激活。首屏失败最多回滚一次。
直接 `https://...lynx.bundle` 仍然绕过 OTA，不写入 OTA Store。

### 宿主 App 生命周期（监控旁路）

Router 不会抢占业务 App 的生命周期。三端宿主需要把系统事实转交给两个公开入口：

```text
Android    Application/ProcessLifecycle：onApplicationForeground / onApplicationBackground
iOS        SceneDelegate：sceneWillEnterForeground / sceneDidEnterBackground
HarmonyOS  UIAbility：onForeground / onBackground
```

这些入口同时驱动 OTA 的启动/回前台同步（仅 foreground）和 Telemetry 的 App 状态广播；页面
`onPause`、`viewWillDisappear`、`aboutToDisappear` 只表示页面可见性，不能替代 App background。
监控默认 Noop Sink，不联网、不落盘，不会阻塞路由。

调试表单也可使用便捷入口：

```swift
try LynxShell.open(
    bundleURL: "https://cdn.example.com/product.lynx.bundle",
    title: "商品详情",
    initialDataJSON: #"{"id":"10001"}"#,
    globalPropsJSON: "{}",
    fullscreen: true
)
```

Sample Bundle 位于 `ios/LynxShellSample/Resources/Bundles`。Provider 从最终
`Bundle.main` 读取，所以业务工程应把自己的 `.lynx.bundle` 作为 folder reference
加入 App Target，而不是塞进 `LynxShellKit`。

## 三端默认承载与页面侧协议

三端均采用 Native Page Stack：

```text
Android  -> Activity-first（LynxShellActivity）
iOS     -> UINavigationController + UIViewController
Harmony -> ArkUI Router + LynxContainer Page（NavPathStack 可替换适配层）
```

页面侧仍只依赖 `NativeModules.LynxShellModule` 的 `open/redirect/close/back/popTo/closeAll`
等语义，不读取 Activity、UIViewController 或 ArkUI 的实现细节。中性身份字段、生命周期
事件和双向消息见 [ROUTER_CONTRACT_V1.md](ROUTER_CONTRACT_V1.md)。

## 页面侧 NativeModules 不变

Module 化只改变原生代码的打包与宿主入口，不改变 Lynx 页面协议：

```ts
const module = NativeModules.LynxShellModule

module.open('product-detail.lynx.bundle', JSON.stringify({
  routeKey: 'product-10001',
  transition: { preset: 'slideFromRight' },
}), callback)

module.close(callback)
module.closeAll(callback)
module.reLaunch(JSON.stringify({ path: 'main.lynx.bundle' }), callback)

module.broadcast('orderUpdated', { orderId: '10001' }, callback)
module.sendToPage(pageId, 'refresh', {}, callback)
module.emitToNative('log', { action: 'pay' }, callback)
```

完整方法、错误码、路由栈语义见 [BRIDGE_CONTRACT.md](BRIDGE_CONTRACT.md) 和
[NAVIGATION_README.md](NAVIGATION_README.md)；转场参数见
[TRANSITIONS_README.md](TRANSITIONS_README.md)。

## Module 边界

- Module 负责：Lynx Runtime、Service、XElement、Container、NativeModules、资源加载、
  路由状态机、页面转场、媒体桥和 consumer keep rules。
- 业务 App 负责：Application/Scene 生命周期入口、真实首页/TabBar Router、Bundle
  资源、Release 域名、权限文案、签名和发布配置。
- Android `Application` 与 iOS `AppDelegate/SceneDelegate` 不进入 Module，避免 SDK
  抢占业务宿主生命周期。
- 当前 Module 仍是一页一个 Activity / UIViewController；Module 化没有改成单
  Activity/单 VC，也没有改变已有转场动画所有权。

## HarmonyOS HAR Module

HarmonyOS 现已补齐与 Android AAR / iOS Pod 对应的可复用 Module：

```text
harmony/
├── lynx_shell_kit/                 HAR Module：Runtime / Container / Provider / Bridge
└── lynx_shell/                     Entry Demo：Ability、首页、Bundle rawfile、@Entry 包装
```

`lynx_shell/oh-package.json5` 现在只显式依赖 `@lynx/lynx-shell-kit`，Demo 的页面入口、路由
和 Runtime 初始化均从该包导入；Lynx、Service、XElement 和 OTA 不需要在 Entry 中重复声明。
HAR 构建命令：

```bash
cd harmony
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleHar --mode module -p module=lynx_shell_kit@default --no-daemon
```

产物为 `harmony/lynx_shell_kit/build/default/outputs/default/lynx_shell_kit.har`。
Demo 使用根工程 `assembleApp` 打包，避免只安装旧的单 HAP 导致 rawfile Bundle 缺失。

Playground `dist/` 的 16 个 `.lynx.bundle` 与 `static/` 已全量同步到
`harmony/lynx_shell/src/main/resources/rawfile/bundles`。Lynx 页面默认不显示原生标题栏，
页面标题、返回和导航由 Bundle 自己绘制。

## 本次验证

- Playground：TypeScript `--noEmit` 与 Rspeedy Bundle 构建通过。
- Android：Library Release AAR 与 Sample Debug APK 构建通过；APK 已安装并启动到
  OnePlus 8 真机，前台为 Module 内的 `LynxShellActivity`。
- iOS：单一 `LynxShellKit` Pod 安装（直接依赖 1 个）、内置 OTA SDK `swift test`
  （16/16）通过；本轮 Pod 结构收口后的 Xcode 编译在 `SWBBuildService` 的 clang 预处理阶段
  卡住，标记为 `[待确认]`，不能用此前的 Simulator 运行证据替代。
- Android/iOS 静态检查为 `110 PASS / 0 WARN / 0 FAIL`；HarmonyOS 专项静态检查为
  `62 PASS / 0 WARN / 0 FAIL`，三端合计 `172 PASS / 0 WARN / 0 FAIL`。
- HarmonyOS HAR/HAP 构建成功；模拟器 `127.0.0.1:5555` 已安装并验收原生 OTA 首页、
  Loading/401 错误态和删除入口。Demo 现在可通过 `serverPlatform=android` 临时复用现有
  Android release；后端开放 `harmony` 后删除该兼容配置即可。
