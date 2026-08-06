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

当前默认首页是 `LynxShellSample/UI/LauncherViewController` 原生壳验收页，不会自动进入
旧的 `main.lynx.bundle`。页面提供 OTA 打开和本地 OTA Bundle 删除入口；业务深链仍然由
`LynxRouter` 解析并进入 Native Page Stack。普通本地 Bundle 仍可放在：

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

页面调用、七种 preset、`onRouteDone`、`prepareRoute / markTransitionReady /
getTransitionState`、两阶段提交和降级规则见根目录
[TRANSITIONS_README.md](../TRANSITIONS_README.md)。
