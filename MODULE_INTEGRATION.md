# LynxShell Android / iOS / HarmonyOS Module 接入

## 目标

三端采用“可复用 Module + Sample App”结构，分别交付 AAR / Pod / HAR：

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
`deleteAllOtaBundles`。两者永久清除远程引用，不生成隐藏备份目录；活体 lease 保护的对象延后回收，
选择模式保留必要 State/lastDecision，`embedded` 描述和 APK assets 保留，回调必须检查 `code === 0`。

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

## OTA 用户注册、版本来源与本地选择

用户只由原生登录系统注册，不新增用户注册 Bridge。install 前注册值（包括显式匿名）优先于配置中的 userId：

```kotlin
// Android：在原生主线程，登录态恢复后、install 前或运行期间调用。
LynxRouter.registerOtaUserId(restoredUserId)
LynxRouter.clearOtaUserId() // 退出时调用，不要在同一次登录初始化中同时调用二者
```

```swift
// iOS：MainActor。Router 校验失败返回 false，不改变当前身份。
LynxRouter.registerOtaUserId(restoredUserId)
LynxRouter.clearOtaUserId() // 等价于注册 nil
```

```ts
// HarmonyOS：UI 线程。
LynxRouter.registerOtaUserId(restoredUserId)
LynxRouter.clearOtaUserId() // 等价于注册 undefined
```

这些示例分别表示登录/退出事件，不是要求紧接着执行。重复注册相同规范化身份不重建 Tab、不重复同步。
Android/Harmony Router boolean 表示是否变化；iOS Router boolean 表示参数是否被接受，不能统一当作 changed，更不能当作网络完成结果。
需要等待身份变更触发的同步时复用现有主动刷新入口，同 epoch 在途全量任务会合并。userId raw 输入先拒绝控制字符，再 trim，最多 256 UTF-8 字节；不写原始账号到 State/日志。

所有新版 latest 全量/定向/repair/主动刷新都发送 `versioncode`、`lynxSdkVersion`，有用户才发送 userId。
`versionCode` 配置可显式覆盖合法原生构建码，但不从版本名称、去掉小数点或固定 BUILD_NUMBER 推导。

| 平台 | 默认构建码 | Lynx SDK 版本及边界 |
|---|---|---|
| Android | PackageInfo.longVersionCode（旧 API 用 versionCode） | Library 当前 resolved variant 生成 `BuildConfig.LYNX_RUNTIME_VERSION`；不是误报的 JNI getter。宿主强换预编译 AAR 的 Runtime 未认证，必须重建/验证组合 |
| iOS | 整数 CFBundleVersion；如 1.2.3 必须显式提供正整数 versionCode | 可信 `org.cocoapods.LynxResources` / `org.cocoapods.Lynx` metadata；多源或显式值不一致则配置失败 |
| HarmonyOS | 自身 BundleInfo.versionCode | 实际 `@lynx/lynx` HAR 的 `LynxEnv.getLynxVersion()`；显式 SDK 值也须与实际值一致；platform 固定 harmony |

构建码是十进制字符串 `1..9223372036854775807`，SDK 是 1–3 段稳定数字版本，二者与 appVersion/versionName/buildNumber 独立。
非法配置不能发送伪造的 0 或悄悄省略新参数；Shell 保留独立 embedded 加载能力并报告 OTA 配置错误。
Android/iOS Core 的 `versionCode=null/nil` 只为旧低层调用保留，不是新版 Router 的默认接线方式。

Server 在用户资格及范围过滤后比较 releaseSequence，因此 full7 胜 gray6；较高 policyRevision 可回滚到较低 releaseSequence。
State v3 的 current/previous/candidate ref 保存 selection，lastDecision 保存 audience/context 摘要、revision/action/target；CAS 只按 App ID/SHA 保存一份 bytes。
旧 v3 unknown 引用须重新确认；所有新入口重检用户及 native/SDK 范围，旧用户 gray 不能作为 previous 回退。
Harmony 没有 candidate/trial。Android/iOS 首屏回调携带捕获的 releaseId/epoch，旧回调不能确认或清除新 candidate。

Native Tab 普通切换 cache-only；普通后台更新保持实例。身份变化或主动刷新完成后，在有效 epoch 下 reset Snapshot、更新 generation 并重读已提交 State。
即使整批 partial failure，其他 App 已完成的更新或 embedded 指令也必须可见；只给成功 App 更新刷新门控，不把 partialResult 视作全量成功。
full/gray metadata 或用户变更不复制 CAS。100→1 只下载缺失 1、复制 0；有界 GC 后旧回滚对象不在磁盘时允许补下载，不能无限保留历史。

### 三端匿名内置 baseline 下载

三端共用 `android/app/scripts/sync_ota_bundles_to_assets.mjs`。从仓库根运行，事先由安全环境提供
`LYNX_OTA_CLIENT_TOKEN`；下面的构建码是示例，必须替换为本次目标原生包的实际值：

```bash
node android/app/scripts/sync_ota_bundles_to_assets.mjs \
  --base-url https://ota.example.com --env TEST --host-app capp \
  --target android --platform android --versioncode 120 --lynx-sdk-version 4.0.0

node android/app/scripts/sync_ota_bundles_to_assets.mjs \
  --base-url https://ota.example.com --env TEST --host-app capp \
  --target ios --platform ios --versioncode 800 --lynx-sdk-version 4.0.0

node android/app/scripts/sync_ota_bundles_to_assets.mjs \
  --base-url https://ota.example.com --env TEST --host-app capp \
  --target harmony --platform harmony --versioncode 25 --lynx-sdk-version 4.0.0
```

`--versioncode` 与 `--lynx-sdk-version` 必填，SDK 值也必须对应实际打包依赖。`--platform` 默认等于 target，显式提供也必须一致。
脚本始终匿名，不接收 userId，只接受兼容 full 完整快照；gray/directive/校验失败不覆盖既有内置目录。
可加 `--dry-run` 下载校验但不替换资源，或用 `--output-dir` 指向专用测试目录。普通 `sync_bundle.sh` 只复制本地 dist，不能用来代替上述 Server 选择校验。

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

2026-09-06 user-gray/versioncode：

- [iOS 当前报告](docs/ios-ota-user-gray-test-report.html)：83 Core、最终 4/4 UI、19 图，Pod/宿主链已有当前证据。
- [Android 当前报告](docs/android-ota-user-gray-test-report.html)：87 tests，0 failure/error/skipped，APK 构建及 HTML 验收通过。
- [Harmony 当前报告](docs/harmony-ota-user-gray-test-report.html)：host-final3 mode=all 18/18（5真实HTTP）＋Core25/25，0失败/跳过；release HAR 3.981s、App 6.565s 构建成功，静态90/0/0。HTML展示验收独立于这些门禁。
- Server：实际 npm pack Contracts 本地产物联编125/125、0 skipped；只读 backfill preview 44 scopes/372 local rows。没有npm发布、远程DB操作或部署。

本次 Android/Harmony 设备测试已由用户取消，只采用自动/协议测试、构建与 HTML 层级，不写成设备通过。
此前 Module 化阶段的 16 项 Swift、OnePlus/旧 HDC、172 项静态等记录属于历史，不再代表当前结果。
历史基础证据另见 [iOS v3](docs/ios-ota-store-v3-test-report.html)、[Android v3](docs/android-ota-store-v3-test-report.html)、[Harmony v3](docs/harmony-ota-store-v3-test-report.html)。
