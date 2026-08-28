# Lynx Navigation to OTA：Lynx 4.0 三端原生壳

这是一套面向业务 App 的 **Lynx 4.0 三端原生宿主壳**。工程不是把官方 Explorer 或 Sparkling Playground 原样复制进业务仓，而是按原生平台习惯重新拆分 Runtime、Container、Provider、Router、Native Module、安全策略和错误态。

参考边界：

- Lynx `release/4.0` Explorer：Android、iOS、HarmonyOS 的 Runtime 初始化、Service、`LynxView`、资源 Provider、Native Module、`initData`、`globalProps`、尺寸与生命周期。
- Sparkling `main/packages/playground`：iOS 默认首页复刻其 ReactLynx 页面和多 Bundle 组织方式。
- 默认主链路直接接入 Lynx 4.0；只复用 Playground 页面，不引入 Sparkling 原生 SDK。前端通过 `NativeModules.LynxShellModule` 调用当前壳手写能力，不使用 autolink。

## 交付结构

```text
LynxNativeShells-4.0-XElement-Full-Android-iOS-Harmony/
├── android/                     # Android Library Module + 可运行 Sample
├── ios/                         # CocoaPods LynxShellKit Module + 可运行 Sample
├── harmony/                     # ArkTS + ArkUI + Stage 模型
├── playground/                  # ReactLynx 多 Bundle 首页与 typed NativeModules wrapper
├── examples/                    # Android/iOS 完整与 HarmonyOS 基础 NativeModules 声明
├── scripts/                     # 三端 Bundle 同步与静态验收
├── PROJECT_MAP.md               # 当前架构、关键源码和数据流索引
├── MODULE_INTEGRATION.md        # 双端 Module 安装、宿主接线与调用
├── ARCHITECTURE.md
├── BRIDGE_CONTRACT.md
├── ROUTER_CONTRACT_V1.md
├── COMPATIBILITY.md
├── HARMONY_INTEGRATION.md
├── XELEMENT_INTEGRATION.md
├── NAVIGATION_README.md
├── TRANSITIONS_README.md
├── ROUTING.md
├── SECURITY.md
├── SOURCE_MAPPING.md
└── VALIDATION.md
```

三端对齐主线是根目录的 `android/`、`ios/`、`harmony/`。此前独立的
`LynxScreens-Android` 工程不属于本仓库，避免与当前 Activity-first Router 混淆。

## GitHub Pages API 文档

仓库已提供一份可直接发布的静态 API 文档页：

- 本地文件：[docs/index.html](docs/index.html)
- Bundle 路径说明：[docs/lynx-bundle-paths.html](docs/lynx-bundle-paths.html)
- Bundle/OTA 验收清单：[docs/lynx-bundle-ota-test-checklist.md](docs/lynx-bundle-ota-test-checklist.md)
- Bundle 版本可见性测试：[docs/lynx-bundle-version-visibility-test-case.md](docs/lynx-bundle-version-visibility-test-case.md)
- Android OTA 验收报告：[docs/android-ota-test-report.html](docs/android-ota-test-report.html)
- iOS OTA 验收报告：[docs/ios-ota-test-report.html](docs/ios-ota-test-report.html)
- HarmonyOS OTA 验收报告：[docs/harmony-ota-test-report.html](docs/harmony-ota-test-report.html)
- 在线入口：`https://fulisadawang.github.io/lynx-navigation-to-ota/`
- 页面内容：接口搜索与切换、请求头、全量/定向 `latest-bundle-list`、Manifest、策略匹配、
  结果上报、Bundle 校验、错误处理和三端状态。

仓库已包含 `.github/workflows/deploy-pages.yml`，使用 GitHub Actions 构建并发布 `docs/`；
GitHub 仓库设置中选择 **Settings → Pages → Source → GitHub Actions**。页面中的示例令牌、
Base URL 和 CDN 地址都是占位符，不包含真实凭证。

## 平台实现

| 平台 | 原生页面模型 | Runtime 入口 | Bundle 容器 |
|---|---|---|---|
| Android | `android/lynx-shell`，一个页面一个 `LynxShellActivity`；Native Tab 使用 `Fragment` | `LynxRouter.install + LynxOtaConfig` | Activity-first Page + Fragment Tab；Router AAR 内置 OTA；默认沉浸式 `LynxView` |
| iOS | `LynxShellKit`，一个页面一个 `LynxContainerViewController`；Native Tab 使用原生 `UIViewController` | `LynxRouter.install(to:otaConfiguration:)` | UINavigationController + UIViewController Tab；默认沉浸式 `LynxView` |
| HarmonyOS | `lynx_shell_kit`，一个 ArkUI 路由页一个 `LynxContainer`；Native Tab 使用 ArkUI Tabs | `LynxRouter.install(context, otaConfig?)` | ArkUI Page/Container + ArkUI Tabs；默认沉浸式 `LynxView` |

### 三端 OTA Store v2 与 Native Tab

三端的普通页面和 Native Tab 都由原生容器承载，但两条加载策略明确分开：普通页面可以按平台
配置执行后台版本检查或候选版本流程；Native Tab 只读取已经提交的 `current`，普通 Tab 切换不
发起网络请求，用户主动刷新或下一次冷启动再消费新版本。

| 平台 | 普通页面容器 | Native Tab 容器 | Store 版本角色 |
| --- | --- | --- | --- |
| Android | `Activity` | `Fragment + BottomNavigation` Demo | `current + previous`，可选 `candidate/trial` |
| iOS | `UIViewController` | `UIViewController + UITabBarController` Demo | `current + previous`，可选 `candidate/trial` |
| HarmonyOS | `ArkUI Page/Container` | `ArkUI Tabs` Demo | 只有 `current + previous`，不加入 candidate |

远程 Bundle 在三个平台都按 App ID 物理隔离：

```text
<private-app-storage>/lynx-ota-store/apps/<lynxAppId>/
├── state.json
├── releases/<releaseId>/
└── .staging/<releaseId>.<transactionId>/
```

embedded Bundle 仍从 Android assets、iOS App Bundle 或 HarmonyOS rawfile 直接读取，不复制到
OTA Store。远程 Bundle 才写入上面的私有目录；`current/previous` 由原子 state 提交，活体页面或
Tab 通过 Release lease 防止正在使用的目录被清理。Android/iOS 可以按需开启 candidate/trial，
HarmonyOS 按本项目约定不创建 candidate 文件、字段或 API。

三端默认模式统一称为 **Native Page Stack**：统一的是 `open(bundle, params)`、
`replace/pop/popTo/closeAll`、页面身份、生命周期和消息语义，不复制 Android 的
Activity/ViewStack/Fragment 实现。具体协议见 [ROUTER_CONTRACT_V1.md](ROUTER_CONTRACT_V1.md)。

三端均包含：

- 本地 App 资源与远程 HTTPS `.lynx.bundle`；
- `initData`、`globalProps`、标题、全屏、导航栏、状态栏、方向、背景色与尺寸；
- 错误态与重试；普通本地/HTTPS Bundle 首帧前使用容器背景兜底，Activity-first OTA
  在下载与校验阶段显示原生 Loading，避免空 LynxView 闪白/闪黑；
- Provider 生命周期与请求取消；
- `LynxShellModule`：页面打开、关闭、隔离存储、App 信息、页面消息与生命周期事件；
- Android/iOS 高级导航：launch mode、delta、popTo、清栈、主页、重定向、栈查询、
  页面结果、防重复与恢复；
- Android/iOS Skyline 风格原生容器转场：七种 preset route、多 share-element、
  Open Container 双内容裁剪、Bundle 预取、`onRouteDone`、首帧门禁和跟手返回；
- Explorer、Sparkling 与统一壳路由格式；
- 远程 Bundle HTTPS、20 MB 上限与 HTTP 默认关闭；
- 平台原生代码风格和中文职责注释。

## 三端对齐 API 文档（v1）

这一节是业务方真正需要依赖的公共契约。三端统一的是调用语义、参数字段、返回码、页面
身份、生命周期和消息方向；底层容器仍保持平台习惯：Android 用 Activity-first，iOS 用
`UINavigationController + UIViewController`，HarmonyOS 用 ArkUI Page/Router。业务不需要
注册 `routeId`、维护 route-to-bundle 映射，也不需要知道 current Bundle 的绝对磁盘路径。

### 1. 模块边界和一次性安装

| 平台 | 业务只引入 | 默认容器 | 初始化入口 |
| --- | --- | --- | --- |
| Android | `android/lynx-shell` | 一个 Bundle 一个 `LynxShellActivity` | `LynxRouter.install(application, otaConfig)` |
| iOS | `LynxShellKit` CocoaPods | `LynxContainerViewController` | `LynxRouter.install(to:otaConfiguration:)` |
| HarmonyOS | `@lynx/lynx-shell-kit` HAR | `LynxContainer` ArkUI Page | `LynxRouter.install(context, otaConfig)` |

Android：

```kotlin
// Application.onCreate()，只安装一次。令牌从业务的安全配置注入，不要写死进源码。
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        val ota = LynxOtaConfig(
            apiBaseUri = URI.create("https://ota.example.com"),
            hostApp = "capp",
            defaultLynxAppId = "10000001",
            environment = "PROD",
            platform = "android",
            clientToken = BuildConfig.LYNX_OTA_CLIENT_TOKEN,
        )
        LynxRouter.install(this, ota)
    }
}

// 在 Application/进程前台回调中调用；每次触发全量 latest-bundle-list 同步。
fun onApplicationForeground() {
    LynxRouter.onApplicationForeground()
}
```

```gradle
// 业务方只需要 Router Module；OTA 实现已经编译在同一个 Module 内。
implementation(project(":lynx-shell"))
```

iOS：

```swift
// Scene/Root NavigationController 建立后安装一次。
let ota = LynxOtaConfiguration(
    apiBaseURL: URL(string: "https://ota.example.com")!,
    hostApp: "capp",
    defaultLynxAppId: "10000001",
    environment: "PROD",
    clientToken: secureRuntimeToken
)
try LynxRouter.install(to: navigationController, otaConfiguration: ota)

// Scene 回到前台时调用。
LynxRouter.onApplicationForeground()
```

```ruby
# Podfile：不再单独引入 OtaIOSSDK。
pod 'LynxShellKit', :path => '../lynx-navigation-to-ota/ios'
```

HarmonyOS：

```ts
// EntryAbility.onCreate()，只安装一次。
const ota = new LynxOtaConfig('https://ota.example.com')
ota.hostApp = 'capp'
ota.environment = 'PROD'
ota.platform = 'harmony'
ota.clientToken = secureRuntimeToken
// 服务端暂不接受 harmony 时，可临时设置 ota.serverPlatform = 'android'；
// 这只影响服务端查询，不改变页面的 HarmonyOS 身份。
LynxRouter.install(this.context, ota)

// Ability 回到前台时调用。
LynxRouter.onApplicationForeground()
```

如果只使用本地/直连 Bundle，也可以不传 OTA 配置安装 Router；这时调用 OTA API 会得到
`1004`（runtime 未安装），而普通页面导航不受影响。令牌只允许从宿主安全配置、构建注入或
运行时密钥服务读取，不能放在 `params`、Lynx 页面代码、README、日志或 Git 历史中。

### 2. Bundle 打开契约：直连和 OTA 必须明确区分

路由只有两种来源模式，调用方不要让 SDK 猜测：

| 模式 | 业务输入 | SDK 行为 | 是否进入 OTA |
| --- | --- | --- | --- |
| Direct Bundle | `bundle`/完整 HTTPS URL + `params` | 直接交给 Provider 加载；本地资源从 App 包读取 | 否 |
| OTA Bundle | `lynxAppId` + Manifest 中精确的 `bundleName` + `params` | 按 appId 查 current；缺包时 Loading，下载、size/SHA 校验、staging、原子激活后再创建容器 | 是 |

`bundleName` 是逻辑文件名，不是 URL、不是本地绝对路径。例如 `pay.lynx.bundle`；同一个
文件名在一个 appId 的 Manifest 中只能精确匹配一个 Bundle。业务不需要在原生注册它，也不
需要把 `.bundle` 再拼接一次。

#### Android 调用

```kotlin
// 1) 本地 App 资源：不进入 OTA。
LynxRouter.open(
    this,
    "assets://bundles/home.lynx.bundle",
    params = mapOf("from" to "native", "tab" to "home"),
)

// 2) 远程直连：URL 本身就是资源身份，不查询 Manifest，不写 OTA current。
LynxRouter.open(
    this,
    "https://cdn.example.com/lynx/pay.lynx.bundle",
    params = mapOf("orderId" to "A-100"),
)

// 3) OTA：只传逻辑 appId + bundleName，Router 内部解析本地 current。
LynxRouter.open(
    this,
    "10000001",
    "pay.lynx.bundle",
    params = mapOf("orderId" to "A-100"),
)
```

#### iOS 调用

```swift
// Direct Bundle。
try LynxRouter.open(
    bundle: "assets://bundles/home.lynx.bundle",
    params: ["from": "native"]
)

// Direct HTTPS Bundle：不会反查 appId，也不参加 OTA 版本门控。
try LynxRouter.open(
    bundle: "https://cdn.example.com/lynx/pay.lynx.bundle",
    params: ["orderId": "A-100"]
)

// OTA Bundle。
try LynxRouter.open(
    lynxAppId: "10000001",
    bundleName: "pay.lynx.bundle",
    params: ["orderId": "A-100"]
)
```

#### HarmonyOS 调用

ArkTS 不使用运行时重载，因此 OTA 入口明确命名为 `openOta`：

```ts
// Direct Bundle 或 Direct HTTPS Bundle。
await LynxRouter.open('assets://bundles/home.lynx.bundle', { from: 'native' })
await LynxRouter.open('https://cdn.example.com/lynx/pay.lynx.bundle', { orderId: 'A-100' })

// OTA Bundle。
await LynxRouter.openOta('10000001', 'pay.lynx.bundle', { orderId: 'A-100' })
```

Direct HTTPS 的共同边界是：URL 不参与 Manifest/current/previous、appId 30 分钟检查、OTA
磁盘缓存或回滚；仍必须通过 HTTPS、2xx、非空响应和 20 MB 上限校验。OTA 的 `bundleUrl` 由
Manifest 提供，业务永远不直接传该下载 URL。

### 3. `params`、`options` 和宿主保留字段

所有平台的 `params` 和 `options` 都必须是可 JSON 序列化的 Object，不能传数组、函数、
原生对象或绝对文件路径。

| 字段 | 所属 | 语义 |
| --- | --- | --- |
| `params` | `open` 的第三个/第二个参数 | 页面业务参数；同时注入 `initData` 和 `globalProps.queryItems` |
| `routeKey` | `options` | 栈操作的稳定页面类型标识；默认使用 `bundleName` 或 Bundle URL |
| `launchMode` | `options` | `push`、`singleTop`、`clearTop`、`singleTask` |
| `title` | `options` | 容器标题/页面上下文；默认 `Lynx` |
| `initData` | `options` | 显式覆盖传给页面的初始化 Object |
| `globalProps` | `options` | 业务 GlobalProps；宿主保留字段会在最后覆盖 |
| `fullscreen` | `options` | 是否 edge-to-edge；不等价于隐藏系统状态栏 |
| `showNavigationBar` / `showToolbar` | `options` | 是否显示宿主导航栏；Lynx 页面默认自绘导航 |
| `hideStatusBar` | `options` | 是否真正隐藏状态栏，需显式传 `true` |
| `backGestureEnabled` | `options` | 是否允许系统返回手势 |
| `orientation` / `screenOrientation` | `options` | `system`/`auto`、`portrait`、`landscape` |
| `backgroundColor` | `options` | `#RRGGBB` 或 `#RRGGBBAA` |
| `width`/`widthPx`、`height`/`heightPx` | `options` | 容器尺寸，必须大于 0 |
| `allowHttpInDebug` / `allowHttp` | `options` | 仅 Debug 明确开启 HTTP；Release 永远拒绝 |
| `animated`、`deduplicate`、`deduplicateWindowMs` | 导航 options | 动画和重复导航控制；默认防重复窗口 350 ms |
| `result` | 导航 options | `closeWithResult` 返回给下一个页面的 JSON Object |

宿主始终覆盖以下 GlobalProps，页面不能通过同名字段伪造页面身份：

```text
containerID                         当前 pageId 的兼容别名
__lynxRouterContainerId             原生容器标识
__lynxRouterPageId                  页面实例唯一标识
__lynxRouterPageKey                 Bundle 默认页面类型
__lynxRouterSessionId               当前 Lynx session
__lynxRouterNavigationModel         固定为 native_page_stack
__lynxRouterPlatformContainer      android_activity / uikit_view_controller / arkui_page
__lynxRouterParams                  当前页面参数对象
```

Android beta2 的 `__lynxBundleRouter*` 字段仍作为兼容别名保留。页面侧只读取这些字段，
不要把它们作为下一次跳转的业务参数继续透传。

### 4. 导航 API 对齐表

#### Native 宿主 API

| 统一语义 | Android | iOS | HarmonyOS | 返回 |
| --- | --- | --- | --- | --- |
| 安装 | `LynxRouter.install(Application, ...)` | `LynxRouter.install(to: ..., otaConfiguration: ...)` | `LynxRouter.install(context, otaConfig?)` | runtime/void；iOS 可能抛错 |
| 打开直连 Bundle | `open(context, bundle, params, options)` | `open(bundle:params:options:)` | `open(bundle, params, options)` | `code/message/data` |
| 打开 OTA Bundle | `open(context, appId, bundleName, params, options)` | `open(lynxAppId:bundleName:params:options:)` | `openOta(appId, bundleName, params, options)` | `code/message/data` |
| Scheme | `openScheme(context, scheme, ...)` | `openScheme(_:, ...)` | `openScheme(scheme, ...)` | 同上 |
| 原位替换 | `replace(context, bundle, ...)` | `replace(bundle:...)` | `replace(bundle, ...)` | 同上 |
| 关闭当前页 | `pop(context)` | `pop()` | `pop()` | 同上 |
| 回到目标页 | `popTo(context, pageKey)` | `popTo(pageKey)` | `popTo(pageKey)` | 同上 |
| 关闭当前 Lynx session | `closeAll(context)` | `closeAll()` | `closeAll()` | 同上 |
| 清栈后打开 | `reLaunch(context, bundle, ...)` | `reLaunch(bundle:...)` | `reLaunch(bundle, ...)` | 同上 |
| 查询活体页面 | `activePages()` | `activePages()` | `activePages()` | 页面身份列表 |
| 全局通知 | `broadcast(name, payload)` | `broadcast(name, payload:)` | `broadcast(name, payload)` | 受影响页面数 |
| 定向通知 | `sendToPage(pageId, name, payload)` | `sendToPage(pageId, eventName:, payload:)` | `sendToPage(pageId, name, payload)` | 是否发送成功 |
| 删除指定 OTA | `deleteOtaBundles(appId, callback)` | `deleteOtaBundles(lynxAppId:)` | `deleteOtaBundles(appId)` | 直接删除结果 |
| 删除全部 OTA | `deleteAllOtaBundles(callback)` | `deleteAllOtaBundles()` | `deleteAllOtaBundles()` | 直接删除结果 |

Android/iOS 的底层导航调用通常在主线程执行；Harmony 的 `open`/`replace`/`reLaunch` 返回
`Promise`，`pop`/`popTo`/`closeAll` 返回同步结果。三端的结果字段保持一致，不应依赖某个平台
的具体异常类型或 Activity/UIViewController/ArkUI Page 实例。

#### Lynx 页面 `NativeModules.LynxShellModule`

ReactLynx 页面建议使用仓内 `playground/src/lib/navigation.ts` 封装；直接调用时，原始
Module 的方法名和参数如下：

| 方法 | 参数 | 说明 |
| --- | --- | --- |
| `open` | `(route, optionsJSON, callback)` | 打开直连或 Scheme 页面；OTA Scheme 可在 options 中带 `lynxAppId + bundleName` |
| `close` | `(callback)` | 关闭当前页 |
| `back` | `(delta, optionsJSON, callback)` | 在当前 session 回退，最多回到 session 首页 |
| `popTo` / `popToWithOptions` | `(routeKey, [optionsJSON], callback)` | 回到最近目标页面 |
| `closeAll` / `closeAllWithOptions` | `([optionsJSON], callback)` | 关闭当前 Lynx session |
| `reLaunch` | `(optionsJSON, callback)` | 清栈并由宿主 Home Handler 回主页 |
| `redirect` | `(route, optionsJSON, callback)` | 原位替换当前 entry |
| `getNavigationState` | `(callback)` | 读取栈、depth、canGoBack、宿主锚点 |
| `closeWithResult` | `(resultJSON, callback)` | 关闭当前页并给下一个页面返回 Object |
| `consumeNavigationResult` | `(callback)` | 一次性读取页面结果 |
| `prepareRoute` | `(route, optionsJSON, callback)` | 只预取 Bundle 字节，不创建容器；返回一次性 token |
| `cancelPreparedRoute` | `(token, callback)` | 释放尚未消费的预取 token |
| `emitToNative` | `(eventName, payload, callback)` | 页面到宿主的同步请求/回复 |
| `broadcast` | `(eventName, payload, callback)` | 向所有活体页面发消息 |
| `sendToPage` | `(pageId, eventName, payload, callback)` | 向单个页面发消息 |
| `setStorageItem` / `getStorageItem` / `removeStorageItem` / `clearStorage` | 见 TypeScript 声明 | 壳隔离存储，不影响业务其它存储 |
| `getAppInfo` | `(callback)` | 平台、App 版本、Build、系统版本 |

原始 Native Module 约定 `code === 0` 表示成功。仓内 ReactLynx wrapper 为兼容旧页面会把
成功归一化为 `code === 1`，同时保留 `nativeCode`；业务统一使用 wrapper 时不要再次反转。

页面调用示例：

```ts
import { open, back, closeWithResult } from './lib/navigation'

// 直接打开 OTA Scheme；bundleName 是精确文件名，params 是业务对象。
open({
  scheme: 'hybrid://lynxview_page?bundle=pay.lynx.bundle',
  options: {
    lynxAppId: '10000001',
    params: { orderId: 'A-100' },
    launchMode: 'singleTop',
  },
})

back(1)
closeWithResult({ paid: true, orderId: 'A-100' })
```

### 5. Scheme 兼容入口

三端都支持：

```text
hybrid://lynxview_page?bundle=detail.lynx.bundle&title=Detail
lynxshell://open?bundle=detail.lynx.bundle&title=Detail
lynx://open?bundle=detail.lynx.bundle
```

带业务参数时必须 URL 编码；带 OTA 身份时，非 HTTPS Scheme 可以额外提供 `lynxAppId` 和
`bundleName`：

```text
hybrid://lynxview_page?bundle=pay.lynx.bundle&lynxAppId=10000001&orderId=A-100
```

完整 HTTPS URL 不能作为 `bundleName`。如果目标是直连远程 Bundle，应把完整 URL 放在
`url`/`bundle` 参数中，并保持 OTA 字段为空：

```text
hybrid://lynxview_page?url=https%3A%2F%2Fcdn.example.com%2Fpay.lynx.bundle&title=Pay
```

### 6. 页面生命周期、通知和双向通信

原生容器生命周期映射为同一个 Lynx 事件 `lynxRouterLifecycle`：

```json
{
  "pageId": "entry-...",
  "containerId": "entry-...",
  "pageKey": "pay.lynx.bundle",
  "state": "active",
  "reason": "native_container_did_appear",
  "timestampMillis": 1730000000000
}
```

状态固定为 `entering`、`active`、`covered`、`detached`、`destroyed`。页面被覆盖时不是销毁；
只有容器真正移除并释放 LynxView 后才发 `destroyed`。页面销毁后消息中心立即注销，广播不
保存离线消息。

通知方向如下：

```text
Native -> Lynx：broadcast(eventName, payload) / sendToPage(pageId, eventName, payload)
Lynx -> Native：NativeModules.LynxShellModule.emitToNative(eventName, payload, callback)
```

宿主通过 `setMessageHandler` 接收页面消息，回复统一为：

```json
{
  "code": 0,
  "message": "accepted",
  "data": { "requestId": "..." },
  "affectedCount": 1
}
```

`pageId` 只能取 `activePages()` 或 GlobalProps 中的宿主字段，不能由业务自行拼接。

### 7. OTA 更新时序和删除 API

三端 OTA 的调用语义完全一致：

```text
Application 启动 / 回到前台
        ↓
全量 latest-bundle-list（重叠请求合并）
        ↓
页面打开
        ↓
current 存在且 size/SHA 有效：立即加载；当前 appId 30 分钟内检查过则后台跳过
current 缺失/损坏：忽略 30 分钟门控，进入原生 Loading
        ↓
定向 Manifest → 下载 changedBundles → 校验大小 → 校验 SHA-256
        ↓
写入 staging → 原子激活 current，旧版本保留为 previous
        ↓
创建 LynxView；首屏失败最多回滚一次
```

`latest-bundle-list` 是全量 appId 信息，只在启动和回前台请求；页面打开时只针对当前
`lynxAppId` 做 30 分钟门控的后台检查，不会每次切页都请求全量清单。缺包或损坏时必须等待
准备完成，不能先把不存在的绝对路径交给 LynxView。

Native Tab 的规则更严格：首次进入和普通切换只执行 cache-only `resolveCurrent`，不 repair、不
发起页面级网络检查；主动 OTA 同步成功后，宿主显式重建 Tab 以读取新 `current`。因此 Tab 不会
因为每次打开而重复请求服务端，也不会在后台检查期间替换正在显示的实例。

| API | 行为 |
| --- | --- |
| `deleteOtaBundles(appId)` | 永久删除该 appId 在磁盘中的 `state.json`、`releases` 和 `.staging` 下载内容；不生成 `.delete-*` 备份目录 |
| `deleteAllOtaBundles()` | 永久删除所有 appId 的 OTA 下载内容；HAP rawfile、App Bundle 内置资源不受影响 |

删除完成后再次打开 OTA 页面会重新走下载和校验。删除 API 是诊断/验收能力，生产 App 是否
向用户暴露按钮由业务决定。

### 8. 统一结果和错误码

原生 Router 与 `LynxShellModule` 都返回结构化结果；跨端公共字段为：

```json
{
  "code": 0,
  "message": "导航已提交",
  "data": {},
  "affectedCount": 1
}
```

公共错误范围：

| code | 含义 | 典型原因 |
| ---: | --- | --- |
| `0` | 成功 | 导航事务或 OTA 删除已提交 |
| `1` | 业务失败/目标不存在 | 目标 page 不存在，或 wrapper 的失败归一化 |
| `1001` | 参数/路由不合法 | 空 Bundle、非法 JSON、不安全 bundleName、HTTP 被拒绝 |
| `1002` | 当前页面/容器不可用 | 页面已经销毁、Context 无法关联宿主 |
| `1003` | 预取句柄无效 | token 不存在、过期或已消费 |
| `1004` | 能力未安装 | OTA runtime、Home Handler 或平台桥尚未配置 |
| `1006` | 导航事务冲突 | 上一笔原生转场仍在进行 |
| `1500` | 原生/IO/运行时失败 | 下载、校验、文件事务或 Lynx 首帧失败 |

成功只代表原生导航事务已提交，不代表目标 Lynx Bundle 已经完成首帧。页面需要通过
`lynxRouterLifecycle` 或 `onRouteDone`/`onTransitionSettled` 判断最终状态。

### 9. 不允许的调用方式

- 不在业务侧维护 `routeId -> bundle` 注册表；Bundle 名称直接来自调用参数/Manifest。
- 不把 `https://...` 当作 `bundleName`，也不把手机绝对路径放入 `params`、Intent 或 ArkUI
  路由参数。
- 不把 `clientToken` 放入 Lynx 页面、业务 `params` 或 Git 仓库。
- 不覆盖 `__lynxRouter*`、`containerID` 等宿主保留 GlobalProps。
- 不把 Android 的 Fragment、ViewStack、Activity extra 当作跨端公共 API；跨端只依赖
  Native Page Stack 契约。
- 不把 Direct HTTPS Bundle 当成 OTA：直连 URL 不会自动参与 Manifest、缓存、30 分钟检查或
  回滚。

详细的字段、状态机、转场和安全约束继续以以下文档为准：

- [ROUTER_CONTRACT_V1.md](ROUTER_CONTRACT_V1.md)
- [MODULE_INTEGRATION.md](MODULE_INTEGRATION.md)
- [BRIDGE_CONTRACT.md](BRIDGE_CONTRACT.md)
- [NAVIGATION_README.md](NAVIGATION_README.md)
- [ROUTING.md](ROUTING.md)

服务端开发者请阅读 [OTA_SERVER_API_CONTRACT.md](OTA_SERVER_API_CONTRACT.md)。该文档按当前
三端实际代码列出了客户端对接的 5 个 OTA API、OSS/CDN Bundle 下载契约、请求头、请求/响应
JSON、错误状态、CI/CD 发布边界和 HarmonyOS 平台兼容要求。

服务端最小返回模型可以概括为：

```json
{
  "env": "TEST",
  "hostApp": "capp",
  "lynxAppId": "10000001",
  "releaseId": "r20260629_001",
  "platform": "android",
  "status": "ACTIVE",
  "changedBundles": [
    {
      "pageId": 10000001,
      "bundlePath": "pages/10000001/home.lynx.bundle",
      "bundleUrl": "https://cdn.example.com/home.lynx.bundle",
      "bundleSha256": "sha256:<64位小写十六进制>",
      "size": 524288,
      "required": true,
      "prefetch": true
    }
  ]
}
```

其中 `bundlePath` 是服务端必须保留的精确 Bundle 身份，不能只返回 `bundleName`；
`bundleUrl` 是客户端随后直接读取的 OSS/CDN 地址，不携带 OTA API token。当前服务端正式
平台枚举仍为 `android/ios`，HarmonyOS 的临时 `serverPlatform=android` 兼容方式及正式放开
`harmony` 所需的服务端改动，均已在契约文档中标明。

### 三端 OTA 边界

三端现在都保留同一条明确的 OTA 调用边界：

```text
open(bundleUrl, params)                         -> 直接 HTTPS Bundle，不进入 OTA
open(lynxAppId, bundleName, params)             -> OTA Bundle，按 appId + bundleName 查找
```

启动和每次回到前台由宿主触发全量 `latest-bundle-list`；页面命中本地有效 Bundle 时立即
渲染，并按当前 `lynxAppId` 做 30 分钟后台检查；缺包或 SHA/size 校验失败时跳过门控，先
显示原生 Loading，等待定向下载、校验和原子激活。首屏失败最多回滚一次，不会无限重试。

- Android：`android/lynx-shell` 内置 `LynxOtaRuntime`，作为 Activity-first 基线。
- iOS：OTA 源码已随 `LynxShellKit.podspec` 编译进同一个 `LynxShellKit` Module；业务方只需
  引入 `LynxShellKit`，公开 `LynxOtaConfiguration` 与
  `LynxRouter.open(lynxAppId:bundleName:)`。仓内 `ios/OtaIOSSDK/Sources` 只是内部实现与
  独立单测目录，不是业务方的第二个依赖。
- HarmonyOS：`lynx_shell_kit` 已实现同等客户端事务和 `LynxOtaConfig`；当前服务端
  `LynxOtaServer` 的 `platform` 枚举仍只有 `android/ios`，Demo 通过可撤销的
  `serverPlatform=android` 临时复用 Android Release，宿主 `platform` 仍保持 `harmony`。
  服务端正式放开 `harmony` 后删除该兼容配置即可。

令牌只由业务宿主从安全配置注入，不写进 Module、Demo 源码、日志或文档。OTA 删除 API
直接删除本地下载内容，不生成隐藏备份目录；App 内置 Bundle 不受影响。

## XElement 全量边界

“全量”严格以 Lynx `release/4.0` 各平台源码为准，不机械追求三端包名相同：

- Android：10/10 Maven 产物，包含聚合行为和九类组件；
- iOS：10/10 CocoaPods subspec，包含 `Behavior` 与九类组件；
- HarmonyOS：9/9 能力。BlurView、Input/TextArea、Overlay、Refresh、ScrollCoordinator、ViewPager 由 `@lynx/lynx` 原生 Registry 提供；Markdown、SVG、WebView 按官方 Harmony 接入方式补齐。

完整映射见 [XELEMENT_INTEGRATION.md](XELEMENT_INTEGRATION.md)。

## 版本矩阵

| 项目 | Android | iOS | HarmonyOS |
|---|---:|---:|---:|
| Lynx 主版本 | `4.0.0` | `4.0.0` | `release/4.0` |
| PrimJS | `4.0.0` | `4.0.0` | `4.0.0` |
| 平台包版本 | Maven `4.0.0` | CocoaPods `4.0.0` | OHPM `1.4.0` |
| 平台语言 | Kotlin | Swift / Objective-C | ArkTS |

HarmonyOS 的 `@lynx/*` 发布编号是 `1.4.0`，由 `harmony/parameter.json` 统一管理；这不是把 Lynx 主版本降到 1.4。

## 同步业务 Bundle

```bash
./scripts/sync_bundle.sh /absolute/path/to/main.lynx.bundle
```

会同步到：

```text
android/app/src/main/assets/bundles/main.lynx.bundle
ios/LynxShellSample/Resources/Bundles/main.lynx.bundle
harmony/lynx_shell/src/main/resources/rawfile/bundles/main.lynx.bundle
```

三端统一逻辑地址：

```text
assets://bundles/main.lynx.bundle
```

## Android / iOS Module

Android Sample 通过：

```kotlin
implementation(project(":lynx-shell"))
```

iOS Sample 通过：

```ruby
pod 'LynxShellKit', :path => '.'
```

显式引用可复用模块。其他项目的发布/路径依赖、Application/Scene 初始化、主页 Tab
Handler 与原生打开 Bundle 示例见 [MODULE_INTEGRATION.md](MODULE_INTEGRATION.md)。

## 常用路由

```text
lynxshell://open?bundle=main.lynx.bundle&title=订单详情
lynx://open?bundle=main.lynx.bundle
hybrid://lynxview_page?bundle=main.lynx.bundle&hide_nav_bar=1&screen_orientation=portrait
file://lynx?local://main.lynx.bundle?fullscreen=true&orientation=portrait
```

远程地址需要编码后作为参数传入：

```text
lynxshell://open?url=https%3A%2F%2Fcdn.example.com%2Flynx%2Fmain.lynx.bundle
```

三端页面侧 API、直接 `NativeModules.LynxShellModule` 调用、业务 Home
Handler 和完整场景矩阵见
[NAVIGATION_README.md](NAVIGATION_README.md)。

Android/iOS Bundle 默认
`fullscreen=true / showToolbar(showNavigationBar)=false / hideStatusBar=false`：
`LynxView` 延伸到透明状态栏后方，时间、信号和电量仍然可见，页面不叠加原生导航栏。
只有显式 `hide_status_bar=1` 才会真正隐藏状态栏。对象型
NativeModule callback 统一编码为 Lynx `JavaOnlyMap`，不能直接把 Kotlin `HashMap`
传给 `Callback.invoke`。

跨真实 Activity / UIViewController 的多共享元素、Open Container 九项属性、七种
Skyline routeType、系统动画抑制、原生手势与降级规则见
[TRANSITIONS_README.md](TRANSITIONS_README.md)。

## 验收

```bash
python3 scripts/static_check.py
```

当前静态结果以实际执行脚本输出为准：

```text
python3 scripts/static_check_android_ios.py
python3 scripts/static_check.py
```

当前 Playground 还新增了 `go-bundles.lynx.bundle`：内置 565 个
`go.lynxjs.org/lynx-examples` URL，支持搜索、分类、分批加载和 NativeModules 跳转。
Android/iOS 不限制远程 Host；官方 Bundle URL 仍按 HTTPS、后缀、响应码、重定向协议和体积策略校验。

本轮 iOS 使用 iPhone 16 Pro / iOS 18.1 Simulator 完成 CocoaPods/Xcode 编译、安装和
真实 OTA Bundle 加载；Android 保留 OnePlus IN2010 真机 OTA、Native Tab、回退和故障矩阵证据。
HarmonyOS 完成 HAR/HAP 构建、Pura 90 模拟器安装，以及 Store v2、Native Tab、Inspector、lease、
删除、embedded fallback 和冷启动验收；由于本次环境请求 TEST OTA Server 返回 TLS
`SSL_ERROR_SYSCALL`（HTTP code 000），Harmony 运行态使用仅 TEST 可显式开启的 Mock Source，
不把 Mock 结果写成真实 Manifest/OSS 下载通过。真实 Harmony Server 版本差异、物理真机和签名包
仍需单独验收。最终契约审计还在当前 `android/lynx-shell` 补充了远程 HTTPS 与 OTA 字段隔离 guard。
