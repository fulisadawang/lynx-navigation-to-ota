# iOS Lynx 4.0 Shell

技术栈：Swift、UIKit、CocoaPods、Lynx 4.0。

主工程使用 Swift + UIKit；Lynx 能力已经收进显式 CocoaPods Module
`LynxShellKit`，Sample App 不再直接编译壳源码。`Native/LynxNativeRuntime.m` 是薄
Objective-C 包装层，保留官方 Lynx 4.0 API 形态。

## 主要结构

- `LynxShellKit.podspec`：唯一业务接入 Module，统一声明 Lynx 4.0、Service、全量 XElement
  和内置 OTA 源码。
- `OtaIOSSDK/Sources/OtaIOSSDK`：Router 内部 OTA 实现源码；不需要在业务 Podfile 中单独引用。
- `LynxShell`：业务 App 使用的公开 Interface。
- `LynxShellSample/AppDelegate / SceneDelegate`：Sample 生命周期与导航器接线。
- `LynxNativeRuntime`：封装 `LynxEnv`、`LynxConfig`、`LynxView`、globalProps、initData 和布局更新。
- `LynxContainerViewController`：一个页面一个原生容器；默认隐藏原生导航栏并让
  `LynxView` 延伸到透明状态栏后方，显式自定义路由由壳 animator 与 edge gesture 独占。
- `ShellTemplateProvider`：本地 / HTTPS Bundle、协议校验、重定向、体积限制、任务取消与错误回传。
- `LynxRouteParser`：统一解析业务、Explorer 与 Sparkling 路由。
- `LynxShellModule`：页面打开、关闭、隔离存储、AppInfo 与媒体方法。
- `ShellMediaBridge`：相册/相机选择、上传、下载和 Data URL 落盘。

## XElement 4.0 全量接入

`LynxShellKit.podspec` 已显式声明 `Input`、`BlurView`、`Overlay`、
`ScrollCoordinator`、`ViewPager`、`WebView`、`SVG`、`Refresh`、`Markdown` 与
`Behavior` 十个 subspec。Sample 的 Podfile 只直接引用本地 `LynxShellKit`。

`Behavior` 通过官方 `LYNX_LAZY_REGISTER_*` 机制自动完成组件映射，宿主不重复手工注册。`Native/LynxNativeRuntime.m` 还导入了全部组件公开头和 AutoRegistry 头，作为真实编译时的缺失检测哨兵。`project.yml` 与 Debug/Release Target 均加入 `-ObjC`，保证静态 Framework 内的自动注册类被链接。

该范围严格对应 Lynx `release/4.0`，详情见根目录 [XELEMENT_INTEGRATION.md](../XELEMENT_INTEGRATION.md)。

## 工程入口

仓库包含手工整理的 `LynxShell.xcodeproj`，同时提供 `project.yml` 便于使用 XcodeGen 重建：

```bash
cd ios
pod install
open LynxShell.xcworkspace
```

重新生成工程：

```bash
xcodegen generate
pod install
```

当前冷启动默认从原生宿主页自动进入与 Android 一致的 `10000001/home.lynx.bundle` OTA
验收首页；`LynxShellSample/UI/LauncherViewController` 继续作为宿主页锚点，提供“打开 OTA
验收首页”“打开 Playground”“打开原生 Tab Demo”和本地 OTA Bundle 删除入口。调试时传
`--show-native-launcher` 可停留在原生页，业务深链仍优先由 `LynxRouter` 解析并进入 Native
Page Stack。普通本地 Bundle 可放在：

```text
LynxShellSample/Resources/Bundles
```

其他工程显式接入：

```ruby
pod 'LynxShellKit', :path => '../lynx-navigation-to-ota/ios'
```

然后在业务 Scene/Coordinator 中调用 `LynxRouter.install(to:)`；它会同时完成
`LynxShell.bootstrap()` 与 `UINavigationController` 绑定。完整示例见根目录
[MODULE_INTEGRATION.md](../MODULE_INTEGRATION.md)。

如果使用 OTA，仍然只需要 `LynxShellKit`，不需要再增加 `OtaIOSSDK` Pod：

```swift
let ota = LynxOtaConfiguration(
    apiBaseURL: URL(string: "https://ota.example.com")!,
    defaultLynxAppId: "10000001",
    environment: "PROD",
    clientToken: secureRuntimeToken
)
try LynxRouter.install(to: navigationController, otaConfiguration: ota)
```

随后使用 `LynxRouter.open(lynxAppId:bundleName:params:)`。命中本地 current 会立即打开并
后台检查，缺包/损坏时显示原生 Loading；直接 HTTPS Bundle 不进入 OTA Store。

Sample Debug 的 OTA 配置约定：`Info-Debug.plist` 提供测试环境 API 地址，
`LynxOtaClientToken` 只从 `LYNX_OTA_CLIENT_TOKEN` 环境变量或 Xcode Build Setting 注入。
Xcode 的 Run Scheme 可在 **Arguments > Environment Variables** 增加同名变量；命令行构建也可
使用 `xcodebuild ... LYNX_OTA_CLIENT_TOKEN="$LYNX_OTA_CLIENT_TOKEN"`。没有注入 token 时，
Router 会明确安装 `LynxEmbeddedOnlyRuntime`，只读 embedded Manifest，不会请求 OTA，这不是
服务端接口失败。

Sample 默认首页通过 embedded Manifest 按 `bundleName=main.lynx.bundle` 解析真实
`lynxAppId`，再进入同一套 OTA/embedded 选择链路，不再用 `assets://` 绕过 OTA。打开时先
`resolveCurrent` cache-first；命中 remote current 后按 App ID 30 分钟门控后台检查，Tab 只读
`resolveCurrent`。current 首屏失败时先恢复 previous；没有 previous 但存在 embedded baseline
时删除该 App ID 的坏 downloaded current，下一次加载直接回到 App Bundle baseline。

普通横向页面默认开启 iOS 左侧边缘侧滑返回，由壳统一的 edge gesture 驱动可交互 pop；只有
显式 `backGestureEnabled=false` 才关闭。自定义横向转场复用同一套 edge gesture，
`bottomSheet`/`heroSheet` 仍分别使用下拉/纵向关闭，不会被横向手势抢占。

### Sample 全局导航与 Native Tab Demo

Debug Sample 使用 `DemoNavigationController` 作为全局原生导航承载：Lynx 页面打开后显示
原生 `UINavigationBar`、标题、返回按钮和全局 `interactivePopGestureRecognizer`。这只是 Demo
验收模式；业务 App 默认仍由自己的 Coordinator 决定导航栏和返回手势。

Native Tab Demo 的两个 Tab 都从 embedded Manifest 解析 `main.lynx.bundle` 的真实 App ID，
再调用 `resolveCurrent` cache-only 读取同一个 OTA current。Tab Home/Settings 只通过
`native_tab_id` 改变页面展示状态，不更换 Bundle；因此 Tab Home 与单独打开 Playground
`main.lynx.bundle` 的 Bundle、releaseId 和内容来源一致。Demo 顶部“刷新 OTA”会先做一次全量
同步，再让两个 Tab 重新读取已经提交的 current。

## 默认沉浸式容器

iOS 打开任意 Bundle 时默认：

```text
fullscreen=true
showNavigationBar=false
hideStatusBar=false
```

`LynxView` 使用整个 ViewController 的 bounds，内容绘制到透明状态栏后方；时间、信号
与电量仍然可见，前景色按路由背景色自动选择。只有显式
`fullscreen=false + showNavigationBar=true` 才恢复 `UINavigationBar`，显式
`hide_status_bar=1` / `hideStatusBar=true` 才真正隐藏状态栏。

## Debug / Release 网络策略

- Debug Target 使用 `Info-Debug.plist`，便于本地调试；HTTP 仍需路由显式传入 `allowHttpInDebug=true`。
- Release Target 使用 `Info.plist`，`NSAllowsArbitraryLoads=false`。
- HTTPS 不限制 Host；Provider 会重新校验最终重定向协议。

## Sparkling

默认首页只复刻 Sparkling Playground 的 ReactLynx 页面与多 Bundle 组织方式，不接入
Sparkling iOS SDK。页面直接调用 `NativeModules.LynxShellModule`；Module 由 Swift 手写，
并在 `LynxNativeRuntime.m` 中显式注册，不使用 `sparkling-method`、`spkPipe`、codegen
或 autolink。

具体构建方式见根目录 [playground/README.md](../playground/README.md)。

## 高级导航

iOS 已支持：

- `back(delta)`；
- `push / singleTop / clearTop / singleTask`；
- `popTo / closeAll / reLaunch / redirect`；
- `getNavigationState`；
- `closeWithResult / consumeNavigationResult`；
- JSON 可序列化 Scene 栈快照；
- 防重复、UIKit 转场重入保护、动画与侧滑开关。

页面侧和直接 NativeModules 调用、TabBar Home Handler、恢复边界和错误码见根目录
[NAVIGATION_README.md](../NAVIGATION_README.md)。

## 原生容器转场

iOS 始终保持“一页 Lynx = 一个 `LynxContainerViewController`”，并在真实
`UINavigationController` 上运行自定义 animator 与 edge interactive pop。共享元素
支持多元素、shuttle 和内置矩形曲线；Open Container 使用裁剪双内容容器。目标节点
由 Lynx 首屏门禁后原生测量。显式 routeType/transition 的 push、pop、手势和
fallback 都不会再叠加 UIKit 默认动画。

`wx://bottom-sheet` 继续使用 iOS 15+ `UISheetPresentationController`（iOS 13/14 由壳
fallback）。`wx://hero-sheet` 则使用普通全屏透明 VC：原生只负责 bottom-up 进场/退出和
来源快照，Lynx 页面自己的 scroll-view 负责 peek 到全屏的连续滚动和顶部导航渐变，不再
把 hero 映射成 UIKit custom detents，也不让 VC 的纵向手势抢占 Lynx 滚动。

页面调用、七种 preset、`onRouteDone`、`prepareRoute / markTransitionReady /
getTransitionState`、两阶段提交和降级规则见根目录
[TRANSITIONS_README.md](../TRANSITIONS_README.md)。
