# Lynx Router Contract v1

这是 Android、iOS、HarmonyOS 共用的页面语义契约。契约统一的是调用方式和事件字段，
不要求三个平台使用相同的原生容器。

## 默认承载模型

| 平台 | 默认页面容器 | 默认页面栈 |
| --- | --- | --- |
| Android | `LynxShellActivity` | Activity Task（Activity-first） |
| iOS | `LynxContainerViewController` | `UINavigationController` |
| HarmonyOS | `ShellNavigationHost` 中的 `NavDestination + LynxContainer` | `Navigation / NavPathStack` |

Android 的 ViewStack 和 Fragment 不是 v1 的跨端容器：ViewStack 是 Android 可选优化，
Fragment 只用于旧工程兼容。

HarmonyOS 当前源码由宿主挂载 `ShellNavigationHost`，以 `Navigation / NavPathStack` 承载
真实页面栈。`ShellNavigationAdapter` 对接原生可取消的 transition proxy，`LynxNavigator`
维护提交后的逻辑 entry；公开 Bundle、params、session、生命周期和消息契约保持。标题栏和
业务导航仍由 Lynx 自绘，使用原生栈不等于使用原生导航栏。宿主未挂载时返回 `1004`，仅已
初始化、等待实际 Area-ready 的阶段有界排队。2026-10-05 本轮仅完成源码和独立审查，尚未构建或运行验收。

## Sample 启动页基线

三端 Sample 的启动页是原生壳验收页，不是默认 Lynx `main.lynx.bundle` 页面：

- Android：`MainActivity + activity_launcher.xml`；
- iOS：`LauncherViewController`；
- HarmonyOS：`pages/Index`。

三端启动后都应先展示中文的原生壳说明和验收入口，不能在没有外部深链时自动 push
`main.lynx.bundle`。启动页至少要明确区分本地 Bundle、直接 HTTPS Bundle 和 OTA 入口；
清理 OTA Bundle 的按钮必须显示真实平台能力状态，不能在没有 OTA SDK 时伪造成功。

## 页面打开

调用方只需要传 Bundle 和参数，不需要注册 routeId，也不需要维护 route-to-bundle 映射：

```text
open(bundle, params)
open("pay.lynx.bundle", { orderId: "123" })
open("https://cdn.example.com/pay.lynx.bundle", { orderId: "123" })
```

Bundle 文件名作为默认 `pageKey`；同一个 Bundle 多次打开仍由 `pageId` 区分实例。
`hybrid://lynxview_page?bundle=...` 是兼容入口，解析后仍进入默认 Native Page Stack。

### 页面语言标识

宿主的 App 语言由 `LynxShellModule.setLocale` 统一保存。打开新页面时，三端 GlobalProps
都会带当前的 `locale`/`language`，Playground 的 `navigate` 和 `open` wrapper 还会在
`hybrid://lynxview_page` / `lynxshell://open` 路由上补一个 canonical `locale` query；已有
旧值会被当前 App 状态覆盖。页面只读取 GlobalProps 或使用自己的资源层，不需要自行从系统
语言推导。

页面资源仍由各 Bundle 管理。每个 Bundle 入口应监听 `lynxShellLocaleChanged`，根据事件中
`revision` 丢弃旧状态，并让自己的资源层调用 `changeLanguage('zh-CN'|'en-US')`。本仓库的
Playground 提供 `LocaleProvider` 和资源注册边界，但不代替业务提交完整翻译内容。

### Window / Foldable 环境

页面应使用 `viewportWidth` / `viewportHeight` 和响应式 Lynx 单位适配可用空间；不要把
Window 的 `screenWidth` 当成页面布局宽度。宿主监听原生 Window/Scene/ArkUI area 变化，
原位更新 Lynx 4.0 screen metrics、viewport 和 GlobalProps，不重建 LynxView、不重新 resolve
OTA、不丢 Native Tab 的 lease/generation。折叠 posture/crease 属于 capability 数据，当前
没有真实官方数据的平台保持 `unknown`，不自动切双栏。

### 路由转场动画

`open` / `push` / `replace` 的 `options` 支持统一的 `animated` 布尔参数，默认值为 `true`：

```text
open("detail.lynx.bundle", { orderId: "123" }, { animated: false })
```

- `animated=true` 或省略：Android/iOS 普通页面保留现有平台转场；HarmonyOS 由同一
  Native coordinator 使用原生时钟与 proxy 驱动普通、preset、Shared/Open 转场；
- `animated=false`：关闭本次打开、替换或命令回退的动画。HarmonyOS 实际使用 `none` 和
  零时长时钟，仍等待真实 proxy 终态，不以计时器伪造提交；
- HarmonyOS `clearTop`、`singleTask`、`back`、`popTo`、`closeAll` 和 `reLaunch` 都经过
  实际 Native driver。手势取消保留 Context/lease，真实 `onTransitionEnd` 成功后才提交逻辑栈；
- 命令选项支持 `deduplicate` 和 `deduplicateWindowMs`：默认 `true/350ms`，窗口为
  `0..5000` 整数，关闭动画时最多 `80ms`。关闭时间窗不允许重入正在进行的 Native 转场。

## 键盘布局策略

页面可在 Router `options` 中传入可选的 `keyboardBehavior`，默认值为 `system`：

```text
keyboardBehavior: system | resize | pan | nothing
```

语义是页面获得输入焦点后，原生容器如何处理软键盘遮挡：

- `system`：使用平台默认策略；
- `resize`：压缩 Lynx 内容可用区域；
- `pan`：将页面内容跟随输入焦点上移；
- `nothing`：不为软键盘调整页面布局。

Android 通过 Window soft-input 策略与 edge-to-edge IME Insets 实现，HarmonyOS 通过
ArkUI `UIContext.setKeyboardAvoidMode()` 实现。该字段只控制布局避让，不承诺在没有输入框焦点时
强制弹出软键盘。HarmonyOS API 13 请求 `nothing`/`none` 会明确拒绝
`keyboard_behavior_nothing_requires_api14`，不会报告成功再退回 `OFFSET`；API 14 及以上使用
`NONE`。iOS 适配层暂时保持平台默认行为。

## Bundle 来源模式

路由必须把“Bundle 的定位方式”和“Bundle 的发行管理方式”分开。三端公开两种明确模式，
不能根据 URL 猜测 `appId`，也不能把裸 HTTPS 地址隐式改写成 OTA Bundle 名称。

### DirectRemoteBundle

```text
open(bundleUrl, params)
open("https://cdn.example.com/pay.lynx.bundle", { orderId: "123" })
```

- `bundleUrl` 本身就是完整资源定位，不需要 `lynxAppId`、Manifest 或 BundleCatalog；
- Provider 直接请求 HTTPS 地址并渲染 Bundle；
- 不写入 OTA current/release，不参与 appId 30 分钟检查、SHA 版本激活或 OTA 回滚；
- 适合外部固定页面、低频页面、调试和明确由 URL 管理版本的页面；
- URL 远程加载仍受三端 Provider 的 HTTPS、2xx、非空和 20 MB 规则约束；
- 如果需要跳转前预取，只能使用 `prepareRoute` 的短时进程内缓存，不能把它当作 OTA 持久缓存。

### OtaBundle

```text
open(lynxAppId, bundleName, params)
open("10000001", "pay.lynx.bundle", { orderId: "123" })
```

- 业务只传 `lynxAppId`、Manifest 中精确的 `bundleName` 和页面参数；
- `bundleUrl`、版本、大小、SHA-256、current/previous 和回滚由 OTA SDK 负责；
- 页面缺包或本地校验失败时，先完成 resolve/verify/download/activate，再提交页面转场；
- 业务不能把 `https://...` 作为 `bundleName`，也不能把手机文件绝对路径传给 Router；
- 同一个远程 URL 可以作为 Manifest 的下载地址，但 URL 不是 OTA 的业务身份。

因此，远程直连与 OTA 的调用边界固定为：

```text
bundleUrl + params                         -> DirectRemoteBundle
lynxAppId + bundleName + params            -> OtaBundle
```

## OTA 生命周期与宿主初始化

业务宿主只需要在原生导航器/Ability 建立后安装一次 Router，并把 OTA 配置和安全令牌传入：

```text
Android   LynxRouter.install(application, LynxOtaConfig)
iOS       LynxRouter.install(navigationController, otaConfiguration: LynxOtaConfiguration)
HarmonyOS LynxRouter.install(context, otaConfig: LynxOtaConfig)
```

三端策略保持一致：

1. App 启动、每次回到前台：请求一次 host 全量 `latest-bundle-list`，重叠事件合并，不受页面
   30 分钟门控影响。
2. 页面打开：本地 `current` 存在且 SHA 有效时立即创建容器；当前 appId 在 30 分钟内检查过
   则不重复请求，超过后后台定向检查该 appId。
3. 本地缺包或校验失败：忽略 30 分钟门控，原生显示 Loading，等待定向清单、size/SHA 校验、
   staging 和原子激活完成后再创建 LynxView。
4. 首屏失败：只回滚一次 previous/embedded；第二次失败展示原生错误页，不无限重试。

删除 API 直接删除磁盘中的 OTA 下载内容，不生成隐藏备份目录；内置 Bundle 不受影响。
Android/iOS 还可由页面通过可选 `LynxShellModule.deleteOtaBundles`/
`deleteAllOtaBundles` 调用，HarmonyOS 对应宿主 `LynxRouter` API。令牌不属于页面参数，必须由
业务安全配置注入。

Harmony 宿主、查询、selection、Manifest 和本地 State 的平台身份都固定为 `harmony`。
当前 `OtaApiClient` 的全量/定向请求实际发送 `platform=harmony`，并校验响应平台；不再通过
`serverPlatform=android` 伪装发布物。当前 Server/Contracts 已支持 Harmony，旧过渡说明不适用。

Harmony `prepareRoute` 复用真实 Provider 预取字节并返回一次性 token，进程缓存上限为
4 条、合计 32 MiB、30 秒；绑定路由、session、来源快照、exact Context 和 epoch。预热 OTA
不进入 TRIAL，页面真实消费才取得独立 lease/候选试运行资格；过期或不匹配记录
`prepared_route_expired` 后使用正常 Provider。token 不写入持久 current，不携带到磁盘导航参数中的字节或 lease。

## 统一操作

| 语义 | 说明 |
| --- | --- |
| `open` / `push` | 在当前 Lynx session 栈顶新增页面 |
| `replace` / `redirect` | 原位替换当前 Lynx 页面，保留当前 entry 身份 |
| `pop` / `close` | 关闭当前页面；session 首页可回到宿主锚点 |
| `back(delta)` | 在当前 session 内回退指定页数 |
| `popTo(pageKey)` | 回到当前 session 中最近的目标页面 |
| `closeAll` | 关闭当前 Lynx session，回到宿主锚点 |
| `reLaunch` | 清空当前 session 后打开新的目标页面；目标由调用参数提供 |

`launchMode` 的 `push`、`singleTop`、`clearTop`、`singleTask` 在三端保留相同含义。
Harmony Native SDK 的 `reLaunch(bundle, params, options)` 等待真实清栈提交后再打开新 session；
旧 Module `reLaunch(optionsJSON)` 仍是返回宿主锚点的 ABI，不凭未知业务 Tab 配置猜主页。

## Lynx GlobalProps 保留字段

这些字段由宿主覆盖，业务传入的同名值不会生效：

```text
containerID                         兼容旧 Shell 字段，等于当前 pageId
__lynxRouterContainerId             当前原生容器标识
__lynxRouterPageId                  当前页面实例唯一标识
__lynxRouterPageKey                 Bundle 默认页面类型标识
__lynxRouterSessionId               当前 Lynx session 标识
__lynxRouterNavigationModel         固定为 native_page_stack
__lynxRouterPlatformContainer      android_activity / uikit_view_controller / arkui_page
__lynxRouterParams                  当前页面参数对象
```

Android beta2 旧字段 `__lynxBundleRouter*` 继续保留为兼容别名。
Harmony NativeTab 另标记 `native_tab_host / arkui_tab_container`，保留独立消息 Context，
不将其计算为 Lynx Page 栈中的结果 receiver。

## 生命周期事件

页面通过 `GlobalEvent` 监听 `lynxRouterLifecycle`：

```json
{
  "pageId": "entry-...",
  "containerId": "entry-...",
  "pageKey": "pay.lynx.bundle",
  "state": "active",
  "reason": "uikit_view_will_appear",
  "timestampMillis": 1730000000000
}
```

状态使用：`entering`、`active`、`covered`、`detached`、`destroyed`。平台原生生命周期必须
同时驱动 Lynx 的 `onEnterForeground/onEnterBackground`，不能只发送业务事件。

## 双向通信

宿主到页面：

```text
broadcast(eventName, payload)          -> 所有活体页面
sendToPage(pageId, eventName, payload)  -> 一个页面实例
```

页面到宿主：

```text
emitToNative(eventName, payload, callback)
```

回包统一为 `{ code, message, data, affectedCount }`。消息中心只持有活体 LynxView/LynxContext
的弱引用或可清理引用；页面销毁后立即注销，不保存离线消息。

## 平台专属能力

Android 可额外暴露 `openFlow`（无 Fragment ViewStack）和 `openFragmentFlow`（legacy），
但跨端页面不得依赖它们。三端默认路径始终是 Native Page Stack。

## Harmony 本轮交付边界（2026-10-05）

完整软件 API 与调用链已通过有界独立源码审查；本轮 61 条手工用例全部未执行，未编译、
未运行 checks、未设备验收。源码闭环不能证明视觉、FPS、GPU 内存峰值或零泄漏。
NativeTab 是宿主锚点，不计入 Lynx entries，也不是返回结果 receiver：首个 Page
`closeWithResult` 无上一 Lynx entry 时为 `1005`，回 Tab 消费结果为 `1002`。
复杂共享元素洞的父 gradient/image 背景无法由代理快照完整复原，preset 默认数值也存在
平台差异；具体范围见 [转场文档](TRANSITIONS_README.md) 与
[本轮报告](docs/harmony-native-parity-v1/implementation-report.html)。
