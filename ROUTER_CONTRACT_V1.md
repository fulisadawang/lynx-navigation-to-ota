# Lynx Router Contract v1

这是 Android、iOS、HarmonyOS 共用的页面语义契约。契约统一的是调用方式和事件字段，
不要求三个平台使用相同的原生容器。

## 默认承载模型

| 平台 | 默认页面容器 | 默认页面栈 |
| --- | --- | --- |
| Android | `LynxShellActivity` | Activity Task（Activity-first） |
| iOS | `LynxContainerViewController` | `UINavigationController` |
| HarmonyOS | `LynxContainer` Page | ArkUI Router（NavPathStack 可替换适配层） |

Android 的 ViewStack 和 Fragment 不是 v1 的跨端容器：ViewStack 是 Android 可选优化，
Fragment 只用于旧工程兼容。

鸿蒙当前构建默认使用 `@ohos.router` 的系统 Page 栈承载 `LynxContainer`。公开的
`LynxRouter` 不暴露 Router 细节，后续如果宿主统一切换到 `NavPathStack`，只需替换
HarmonyOS 适配层，不会改变 Bundle、params、生命周期和消息契约。

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

Harmony 宿主身份始终使用 `platform=harmony`。当前服务端只允许 `android/ios` 时，Demo 可在
过渡期设置 `serverPlatform=android`，它只影响服务端查询、Manifest 和本地 Release 校验，
不改变 AppInfo/GlobalProps，也不改变 Harmony Native Page Stack。服务端正式放开 `harmony`
后删除该兼容值；业务宿主不应长期把 Harmony 发布物伪装成 Android 平台。

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
