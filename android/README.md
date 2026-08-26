# Android Lynx 4.0 Shell

技术栈：Kotlin、Android Views、Material Components、Lynx 4.0。

## 主要结构

- `lynx-shell`：可复用 Android Library，包含 Runtime、Container、Router、转场和
  `NativeModules.LynxShellModule`。
- `LynxShell`：业务 App 使用的公开 Interface，负责初始化、Handler 注入与打开页面。
- `app`：可运行 Sample，只保留 `LynxShellSampleApplication`、`MainActivity` 与 Bundle。
- `LynxRuntimeInitializer`：初始化 Fresco、Image/Log/HTTP Service、`LynxEnv` 和 Native Module。
- `LynxShellActivity`：一个页面一个容器，管理系统栏、Toolbar、错误态和 `LynxView.destroy()`。
- `LynxContainerFactory`：集中配置 Builder、线程策略、尺寸、密度和 globalProps。
- `XElementRuntime`：把 Lynx 4.0 全量 XElement Behavior 统一安装到每个 Builder。
- `ShellTemplateProvider`：本地 / HTTPS Bundle、安全校验、体积限制、取消和错误回传。
- `LynxRouteParser`：解析 Intent、`lynxshell`、Sparkling hybrid 和 Explorer local 地址。
- `LynxShellModule`：Lynx 调宿主的稳定能力协议。
- `ShellMediaBridge` / `ShellMediaPickerActivity`：媒体选择、上传、下载和 Data URL 落盘。

## XElement 4.0 全量接入

`lynx-shell/build.gradle.kts` 已显式声明：

```text
xelement
xelement-input
xelement-overlay
xelement-viewpager
xelement-scroll-coordinator
xelement-svg
xelement-markdown
xelement-refresh
xelement-blur-view
xelement-webview
```

SVG、Markdown、Refresh 所需的 `lynxtextra:0.1.1`、`servalsvg:0.0.2`、
`serval_markdown:0.1.1` 与 `refresh-layout-kernel:3.0.0-alpha` 也由 Library 显式带入。
页面容器统一调用 `XElementRuntime.install(builder)`，内部使用官方
`XElementBehaviors().create()` 聚合注册。`consumer-rules.pro` 同时保留反射入口，
业务侧打开 R8 后会自动合并。

该范围严格对应 Lynx `release/4.0` Explorer，详情见根目录 [XELEMENT_INTEGRATION.md](../XELEMENT_INTEGRATION.md)。

## 使用步骤

1. 在根目录构建统一 Playground：

```bash
cd playground
pnpm build
```

构建会把 16 个普通 Playground Bundle 与静态资源自动同步到 Android assets。当前 Sample 的
默认首页已经切到 OTA 验收用例 `10000001/home.lynx.bundle`；普通 Playground 首页仍保留
在原生 Launcher 的“打开 Playground 首页”按钮中。普通资源入口为：

```text
app/src/main/assets/bundles/main.lynx.bundle
```

2. Android Studio 打开 `android` 目录。Sample 通过以下依赖使用 Module：

```kotlin
implementation(project(":lynx-shell"))
```

3. 其他仓库可复制 Module，或执行 `:lynx-shell:publishToMavenLocal` 后使用
   `com.example.lynx:lynx-shell-android:1.0.0`。
4. 在业务 `Application` 中调用 `LynxShell.initialize(this)` 并注入主页 Handler。

完整接入见根目录 [MODULE_INTEGRATION.md](../MODULE_INTEGRATION.md)。

## Activity-first OTA 页面

当前 Android Router 已经内置 OTA SDK 源码和默认 `LynxOtaRuntime`，三方不需要再额外
引入 `sdk-0.1.0.jar`，也不需要自己实现 `ActivityBundleRuntime`。OTA 的 Manifest、下载、
大小/SHA 校验、staging、current/previous、原子激活、候选版本和回滚都在 `lynx-shell` AAR 内完成。

Application 中只需要安装一次：

```kotlin
LynxRouter.install(
    this,
    LynxOtaConfig(
        apiBaseUri = URI.create("https://lynx-ota-server.example.com"),
        hostApp = "capp",
        environment = "PROD",
        platform = "android",
        clientToken = BuildConfig.LYNX_OTA_CLIENT_TOKEN,
        // 本地 Bundle 有效时，页面打开触发当前 appId 后台检查的间隔；默认 30 分钟。
        pageRefreshIntervalMillis = 30L * 60L * 1000L,
    ),
)
```

本机验收可以把 `lynx.ota.clientToken` 写入 Android 根目录下的
`ota.local.properties`（该文件已加入 `.gitignore`）；CI/发布环境使用
`LYNX_OTA_CLIENT_TOKEN` 环境变量时会优先采用环境变量，令牌不会进入源码和文档。
如果 token 为空，Router 保持 embedded-only：启动、前台和页面缺包路径都不会发 OTA 请求，
不会使用 SDK 的默认测试令牌。

如果业务已经有自己的 OTA 实现，仍可注入 `ActivityBundleRuntime`；这是扩展口，不是
Router 的必选依赖。

### 全量 OTA 同步与 embedded baseline

Android 原生已经有全量同步接口，运行时不需要再实现一套请求层。`Application`
启动和回到前台时，`LynxRouter` 会调用 `LynxOtaRuntime.onApplicationForeground()`，内部
统一走 `OtaSdk.syncLatestBundleLists()`：一次请求当前环境、宿主和平台下全部 App 的
`latest-bundle-list`，再由 SDK 完成 Manifest、Bundle 下载、size/SHA 校验和原子激活。

Android Demo 的“手动触发全量 OTA 同步”按钮也只调用同一个
`LynxRouter.onApplicationForeground()`，用于验收，不会额外请求接口。请求失败时保留已经
激活的 current 和 APK 内置 Bundle。

三端 Demo 的构建期下载脚本位于 `android/app/scripts/sync_ota_bundles_to_assets.mjs`。它复用原生
`OtaApiClient` 的全量接口契约，把响应里的所有 App ID 和 `changedBundles` 下载到目标平台
资源目录；脚本不接受 `--app-id`，不会写死任何身份。全部 Bundle 校验成功后才替换目标
embedded 目录。

```bash
LYNX_OTA_CLIENT_TOKEN='<本机临时注入，不要写入 Git>' \
node android/app/scripts/sync_ota_bundles_to_assets.mjs \
  --target android \
  --base-url 'https://lynx-ota-server.test.huangbaoche.com' \
  --env TEST \
  --host-app capp \
  --platform android
```

iOS 使用 `--target ios --platform ios`；HarmonyOS 使用
`--target harmony --platform android`（当前服务端尚未开放 `platform=harmony`，Harmony
Demo 的 `serverPlatform` 也采用这个兼容值）。

脚本完成后再执行 `:app:assembleDebug`。安装后的 App 启动/回前台仍由原生
`LynxRouter.onApplicationForeground()` 走同一全量接口，OTA current 写入应用私有 Store，
不会改写 APK assets。手动安装运行可用 `android/app/scripts/run_ota_demo.sh`。

`android/app/src/main/assets/bundles/lynx/embedded-bundles.json` 只描述随 APK 发布的
baseline（按 `lynxAppId + bundleName` 定位）；它不是运行时 OTA 下载目录。OTA 下载内容
写入应用私有 OTA Store，下一次打开页面时优先使用已校验的 current，embedded 仅作为
安装包 baseline 和回滚兜底。

Demo 不再根据文件名猜 appId：`MainActivity` 和 `NativeTabDemoActivity` 只使用 Manifest
中唯一匹配 `home.lynx.bundle + main.lynx.bundle` 的 identity。生产宿主仍应从自己的业务/OTA
响应拿到完整的 `lynxAppId + bundleName`，因为同名 Bundle 可以属于多个 appId。

Android 的 embedded baseline 不会在启动时复制到 `filesDir`。命中内置 Bundle 时由
`EmbeddedBundleRegistry` 直接从 APK `AssetManager` 读取、校验 size/SHA 后以 bytes 交给
LynxView；应用私有磁盘只保存远程 OTA 的 `releases`、`states`、`current/previous` 和
`.staging`。

页面跳转只传逻辑身份和参数，不注册 route 映射，也不传手机文件路径：

```kotlin
val returnedBundle = /* 从全量同步结果或业务路由参数取得 */
LynxRouter.open(
    context = activity,
    lynxAppId = returnedBundle.lynxAppId,
    bundleName = returnedBundle.bundleName,
    params = mapOf("source" to "native"),
)
```

`LynxShellActivity` 的顺序与 `base-sparkling` 的稳定做法一致：本地有可用 current/baseline 时先
通过 cache-only 读取直接创建 `LynxView`，不先显示 Loading；命中远程 current 后，页面会在后台
按 appId 30 分钟门控发起一次页面级版本检查，不阻塞当前页面；
本地没有 Bundle 或校验失败时，才显示原生“正在检查 appId/bundleName…” Loading，等待 OTA SDK
下载、大小/SHA 校验和原子激活，再创建 `LynxView`。Application 启动和回到前台则由宿主主动触发一次全量
`latest-bundle-list`，后台更新所有有变化的 appId。Bundle 首屏失败时最多按 appId 回滚一次
并重试，避免坏版本无限循环。没有 current 且没有 runtime 时会直接进入可重试的错误态，
不会创建空白色 LynxView。

普通 Activity 页面可选开启候选版本模式：

```kotlin
LynxOtaConfig(
    /* ... */
    candidateActivationEnabled = true,
)
```

开启后是 `stage candidate -> 页面首次访问进入 trial -> 首屏成功后 healthy promote`；
`current` 在健康确认前保持旧版本。首屏失败只丢弃 candidate，不回滚稳定 current；进程重启
会清理未完成的 trial。Native Tab 始终只读 current，不消费 candidate，也不在切换时联网。

HTTPS 官方 Bundle 示例是 Direct Remote，不携带 `lynxAppId/bundleName`，也不属于 APK
assets 或 OTA manifest。远程下载期间显示“正在加载远程 Bundle…”；如果业务希望完全离线，
必须先把对应官方 Bundle 纳入自己的 OTA 全量清单，而不是给 HTTPS URL 强行添加 appId。

### 键盘布局策略

Android Router 默认保持系统键盘行为。需要按页面控制输入框被 IME 遮挡时，可在
`LynxRouter.open(..., options)` 中传入 `keyboardBehavior`：

```kotlin
LynxRouter.open(
    context = activity,
    bundle = "login.lynx.bundle",
    options = mapOf("keyboardBehavior" to "resize"),
)
```

支持 `system`、`resize`、`pan`、`nothing`。全屏 edge-to-edge 页面使用 `resize` 时，
壳会通过 IME Window Insets 调整 Lynx 内容区域；普通页面仍使用 Android Window 的
`adjustResize`。该配置只控制布局避让，不承诺在没有输入框焦点时强制弹出键盘。

Router 内置实现位于：

```text
lynx-shell/src/main/kotlin/com/example/lynxshell/ota/LynxOtaConfig.kt
lynx-shell/src/main/kotlin/com/example/lynxshell/ota/LynxOtaRuntime.kt
lynx-shell/src/main/kotlin/com/ota/android/sdk/*.kt
```

`LynxOtaRuntime` 会把 `current/ensureBundleReady(appId, bundleName)` 转换为
`PreparedActivityBundle`：本地合法旧版本先开、后台只刷新当前 appId；缺包或本地 SHA
不一致时只请求当前 appId，并在下载、校验和原子激活完成后创建 LynxView。OTA 文件保存在
App 私有目录 `files/lynx-ota-store`，不放进 `assets/ota`。

## 默认沉浸式容器

Android 打开任意 Bundle 时默认：

```text
fullscreen=true
showToolbar=false
hideStatusBar=false
```

也就是 `LynxView` 直接占满 Activity、绘制到透明状态栏和系统导航栏后方，不叠加壳的
Material Toolbar；状态栏图标仍然可见，并按页面背景色自动选择深色或浅色前景。
`LynxPageRequest`、Intent Extra、深链和调试入口使用同一默认值。业务确实需要普通页面
时，可显式传 `fullscreen=false`，并用 `showNavigationBar/showToolbar` 决定是否恢复
Toolbar；只有显式 `hide_status_bar=1` / `hideStatusBar=true` 才真正隐藏状态栏。

原 Material 调试表单没有删除，可用以下方式显式打开：

```bash
adb shell am start \
  -n com.example.lynxshell.debug/com.example.lynxshell.sample.MainActivity \
  --ez lynx_shell.show_native_launcher true
```

Debug 真机验收可直接进入指定入口：

```bash
adb shell am start -S -f 0x10008000 \
  -n com.example.lynxshell.debug/com.example.lynxshell.sample.MainActivity \
  --ez lynx_shell.open_playground true
adb shell am start -S -f 0x10008000 \
  -n com.example.lynxshell.debug/com.example.lynxshell.sample.MainActivity \
  --ez lynx_shell.open_native_tab true
```

这两个 intent 仅是 Debug Sample 的验收入口，Release 构建忽略。

工程未携带 Gradle Wrapper 二进制。Android Studio 可使用本机 Gradle 配置；需要命令行 Wrapper 时，在具备 Gradle 的环境中生成后再提交工程。

## 远程 Bundle

Debug：

- HTTPS 可用。
- HTTP 必须同时满足 Manifest Debug 配置和页面参数 `allowHttpInDebug=true`。

Release：

- Manifest 从系统层关闭 HTTP。
- HTTPS 不限制 Host，但仍校验 URL、响应码、重定向协议和 20 MB 体积上限。

深链和远程脚本安全说明见根目录 [SECURITY.md](../SECURITY.md)。

### OTA 磁盘清理 API

Router 提供两个仅针对“已下载文件”的直接删除入口：

```kotlin
LynxRouter.deleteOtaBundles(returnedBundle.lynxAppId) { success, message ->
    // 只删除该 appId 在 files/lynx-ota-store/releases 下的 Bundle
}
LynxRouter.deleteAllOtaBundles { success, message ->
    // 删除 releases 下全部 appId 的 Bundle
}
```

Lynx 页面可通过 `NativeModules.LynxShellModule.deleteOtaBundles` 和
`deleteAllOtaBundles` 调用同一能力。删除是永久删除，不创建 `.delete-*` 或其它备份目录；
APK assets/embedded 描述保留，失败通过 `code !== 0` 返回，不伪造成功。旧的
`clearOtaCache()` 仍是删除全部下载内容的兼容别名。

## NativeModules

Playground 页面只调用：

```text
NativeModules.LynxShellModule
```

Android 宿主用手写 `LynxModule + @LynxMethod` 暴露导航、存储、AppInfo 和媒体能力，
不接入 `sparkling-method`、`spkPipe`、autolink 或 codegen。

对象型 callback 不能直接返回 Kotlin `HashMap`。当前实现统一通过 Lynx 官方
`Arguments.makeNativeMap` 递归编码为 `JavaOnlyMap`，包含导航栈、转场状态、
AppInfo 和媒体结果中的嵌套 Map/List；否则 Lynx 4.0 会让 JS 收到 `null` 并报告
`HashMap contained in JavaOnlyArray`。

`integration/sparkling/*.sample` 仅保留为历史参考，不进入默认 SourceSet。

## Android OTA 验收

JVM 故障矩阵脚本：

```bash
bash scripts/ota-fault/run.sh --platform android --tier sdk --case all
```

本地真机验收使用 adb 做精确的清理、启动、进程终止和截图，使用 AndroMeld 观察已连接设备。
当前工程没有配置 Espresso/UIAutomator instrumentation target，因此报告不会把 JVM 或静态结果
冒充 Android UI 自动化结果。完整结果见 [Android OTA 测试报告](../docs/android-ota-test-report.html)。

## 高级导航

Android 已支持：

- `back(delta)`；
- `push / singleTop / clearTop / singleTask`；
- `popTo / closeAll / reLaunch / redirect`；
- `getNavigationState`；
- `closeWithResult / consumeNavigationResult`；
- session/entry/order Activity 重建；
- 防重复、动画开关、系统 Back 开关；
- 混合原生栈 `SessionExitHandler` 扩展点。

页面侧和直接 NativeModules 调用、Home Handler 接线、错误码见根目录
[NAVIGATION_README.md](../NAVIGATION_README.md)。

## 原生容器转场

Android 始终保持“一页 Lynx = 一个 `LynxShellActivity`”。共享元素和 Open
Container 由原生 selector、首屏门禁、快照 overlay 与返回状态机实现；ReactLynx
页面不逐帧驱动。七种 Skyline routeType 与 heroSheet 扩展由不同 renderer 处理：heroSheet
只由原生完成透明宿主的 bottom-up 进场/退出，页面自己的 scroll-view 负责上滑和导航渐变；
普通 bottomSheet 仍由原生处理 Sheet 高度。显式自定义转场
在启动和结束 Activity 时都抑制 Window 动画，fallback 也由壳绘制。Android 14+
接入系统 Predictive Back progress，低版本使用兼容 edge 手势。

Android 的目标页门禁不是只等 `onFirstScreen`：还会等待原生节点稳定和下一次
ViewRoot 绘制帧，再抓取目标页快照。首屏后的图片等子资源错误不会再取消整页转场。
source underlay 中已单独飞跃的区域使用邻近背景色回填，不留透明洞，避免两个
Activity Window 交接时闪出主题默认白块。

共享元素反向返回完成后，Activity 会把“source 快照 + 到达终点的共享元素代理”保留
到 Window 真正销毁，再由 `onDestroy` 清理，避免上一页 Surface 恢复前短暂出现空图、
空标题或空价格区域。

页面调用、多共享元素、Open Container 九项属性、`onRouteDone`、`prepareRoute /
markTransitionReady / getTransitionState`、取消语义和真机验收矩阵见根目录
[TRANSITIONS_README.md](../TRANSITIONS_README.md)。
