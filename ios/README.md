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

### iOS OTA Store v2 与磁盘浏览器

iOS 现在与 Android 使用同一套存储契约，但保留平台自己的目录 API。远程 Release 按
`lynxAppId` 物理隔离，默认位于：

```text
Application Support/lynx-ota-store/
└── apps/<lynxAppId>/
    ├── state.json
    ├── candidate.json              # 仅 candidate 模式存在
    ├── embedded.json               # 只保存 baseline 描述，不复制 Bundle bytes
    ├── releases/<releaseId>/
    │   ├── release-manifest.json
    │   └── <bundlePath>
    └── .staging/<releaseId>.<transactionId>/
```

- 普通模式最多保留 `current + previous`；candidate 模式最多再保留一个 candidate。
- 普通 UIViewController 与 Native Tab 在展示远程 Bundle 时持有 Release lease。即使此时发生
  删除、回滚或新版本激活，活体页面仍可继续读取；最后一个页面释放后再回收无引用目录。
- 冷启动先清理无引用 Release 和残留 staging；状态文件损坏时保守跳过，不猜测删除。
- 下载前先清理无引用版本并做可用空间预检；空间不足不会提交半成品 current。
- Launcher 和 Native Tab 导航栏都可进入“OTA 磁盘浏览器”。它只读取快照，展示真实 root、
  App ID、current/previous/candidate/lease、文件树与占用字节，不做 SHA、不触发网络、不修改 Store。

Demo 不迁移旧 Store。需要从旧 schema 验证新布局时，卸载并重装 Demo，直接生成 Store v2。

### iOS OTA 故障测试入口

当前分支已把 SDK/事务层的 iOS 故障矩阵接入脚本：

```bash
bash scripts/ota-fault/run.sh --platform ios --tier sdk --case all
bash scripts/ota-fault/run.sh --platform ios --tier sdk --case F07
```

`swift test` 当前覆盖 47 个测试、8 个测试套件，包含清单/下载/SHA/文件篡改、版本门禁、
`current/previous/embedded/candidate`、提交前后故障、回滚重启恢复、App ID 物理隔离、
有界版本保留、lease、冷启动清理、容量不足和只读诊断快照。Native Tab 的异步结果代际门禁
另有无 Lynx 依赖的快速契约测试：

```bash
ios/scripts/test_lynx_tab_generation.sh
```

`scripts/ota-fault/run.sh --tier device` 仍对未接入统一 device harness 的 case fail-closed；
真实容器/Tab 运行态由已接入的 `LynxShellUITests` Target 执行。当前 iPhone 16 Pro / iOS 18.1
模拟器结果为：无 token 10 tests / 7 passed / 3 expected skip；Debug mock OTA 配置后 9/9 passed，
覆盖 F10/F11/F12/F13/F14/F15/F16。F12 已在真实 canonical store 的 afterRollbackCommit 后
terminate 进程，再冷启动读取 current 的 UI 用例中通过。

### iOS 候选版本安全启用（可选）

`OtaSDKConfiguration.candidateActivationEnabled` 默认是 `false`，保持现有直接激活兼容行为。
开启后，下载校验流程变为：

```text
stageCandidate -> current 保持 V1 -> beginCandidateTrial -> 首屏/健康确认
  -> confirmCandidateHealthy -> current=V2, previous=V1
```

进程在 trial 阶段重启时调用 `recoverInterruptedCandidate` 会清理候选，current 仍保持 V1；
首屏失败路径调用 `discardCandidate`，不会回滚掉原来的稳定 current。`OtaCandidateActivationTests`
已覆盖健康确认和未完成 trial 重启恢复；Android Store v2 也使用同一 candidate 契约。

Sample Debug 可用环境变量打开这条链路：`LYNX_OTA_CANDIDATE_MODE=1`。本轮在 iPhone 16 Pro
模拟器清空 OTA 数据后重新启动，打开 `10000001` 首页并完成首屏确认；state 最终为
`current=downloaded/r20260823_qc8ffc`，对应 candidate 文件已清理。

本轮 iOS 模拟器运行态已在 `iPhone 16 Pro / iOS 18.1` 上完成：

- Launcher、OTA 验收首页、Playground 首页和 Manifest 第一个内置 Bundle 可打开，并显示
  `10000001`、BundleName、Release/构建版本和来源。
- 原生 Tab Home/Settings 可切换 20 次；刷新失败提示出现后，Home 仍保留原 Release。
- Hero Sheet 上滑到全屏、下拉关闭；Bottom Sheet 打开、下拉关闭；原生 Back 可返回。
- 无 token 的 embedded-only 刷新失败保留 current，以及注入 TEST 配置后的远程 OTA 成功、
  冷启动读取和 Tab 刷新均已在模拟器分别验证；token 只作为进程环境变量使用，不写入仓库。
- 真实 TEST OTA 同步后，Inspector 展示 3 个 App ID、53 个文件、约 5.1 MB；顶层没有旧
  `releases/`、`states/` 或 `.staging/`。Native Tab 打开时当前 Release 标记“页面使用中”，
  退出 Tab 后标记消失，证明 lease 随容器生命周期释放。
- 完整左边缘拖动已由 XCUITest 坐标手势通过并返回原生 Launcher；`agent-device` 的高层 swipe
  仍受驱动能力限制只能产生约 7px 位移，这不等同于壳侧滑功能失败。

### XCUITest Target

工程已新增 `LynxShellUITests`：

```bash
cd ios
xcodebuild -workspace LynxShell.xcworkspace \
  -scheme LynxShell \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' \
  -only-testing:LynxShellUITests test
```

无 token 全套结果为 10 tests / 7 passed / 3 expected skip / 0 failures；左边缘返回、Tab 往返和
刷新失败保留已由 XCTest 通过。注入 Debug mock OTA 运行变量后，完整 UI 回归为 9 passed / 1
live-only skip / 0 failed；成功刷新使用真实 embedded Bundle + Router/Tab 链路模拟，Tab 切换的
请求计数、实例和 generation 均有断言，F12 rollback terminate/relaunch 也已通过。真实 OTA
Server 模式为 9 passed / 1 mock-only skip / 0 failed，live smoke 单项 1/1 通过。

独立 HTML 测试报告：[ios-ota-test-report.html](../docs/ios-ota-test-report.html)，包含 live、mock、
无 token 三组结果、用例筛选、证据展开和可追溯源码链接。

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
