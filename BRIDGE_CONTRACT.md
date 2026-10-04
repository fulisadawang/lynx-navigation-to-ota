# LynxShellModule 三端 Bridge 协议

模块名：`LynxShellModule`

- Android：`LynxModule` + `@LynxMethod`；
- iOS：`LynxModule.name` + `methodLookup`；
- HarmonyOS：ArkTS `LynxModule`，在 `LynxView.modules` 中注册。

基础 `open/close`、存储和 AppInfo 三端方法名保持一致，UI 导航动作必须进入平台
UI 线程/路由上下文。

## 业务事件与分组

三端在现有模块新增必需接口，项目上线前一次对齐：

```ts
reportBusinessEvent(
  group: string,
  name: string,
  attributesJSON: string,
  callback: (result: BusinessEventNativeResult) => void,
): void;
```

页面使用 `@cclx/lynx-native-bridge/shell/business-events` 的对象 API，由包内编码 attributesJSON。group/name 和属性字段由业务方自由定义、支持中文，不需要注册或业务枚举；属性只允许扁平 string、finite number、boolean，未提供属性由页面封装传 `{}`，显式 null/数组/嵌套对象不接受。

原生根据调用者 Context 对应的 View/Binding 生成事件身份与接收时间；不接受页面覆盖 viewId、Bundle、平台或时钟。所有监控事件使用统一 Schema 1.0、顶层必填 `group`；默认系统组为 page（lifecycle/load）、performance、error、resource、diagnostic，业务组取调用方原值。group 用于筛选，不改变 eventType、Provider 能力、采样或队列优先级。

### 回执和错误

成功对象为 `code=0,message,data={stage:'queued',eventId,monitorState:'initializing'|'ready'}`，仅在 Core 真正 append 后返回。Provider/SDK/网络/后台接受是后续阶段，不能解释为此 Promise 已证明送达。回调最多一次；页面 runtime 销毁后按 SDK 生命周期丢弃回调，不补假成功。

失败对象为 `code,message,data={stage:'rejected',reasonCode}`：

| code | reasonCode | 含义 |
|---:|---|---|
| 1001 | invalid_argument | 分组/名称为空或全空白、JSON/属性类型非法 |
| 1001 | event_too_large | 原始输入或完整快照超 32 KiB 预算 |
| 1002 | page_context_unavailable | 调用者 View/活动 Scope 无法确定或已关闭 |
| 1004 | not_configured | 未启用监控或未配置 Provider |
| 1004 | not_ready | 监控初始化已失败或不可再接收；initializing 本身仍可排队 |
| 1004 | monitor_closed | 监控 Core 已关闭 |
| 1004 | event_unsupported | Provider 未支持 business.event |
| 1004 | queue_rejected | 无法在保护核心事件的前提下接受本条业务事件 |
| 1500 | internal_error | 意外内部异常 |

业务分组、名称、属性 key 保留原文，不自动 trim/改名，不新增 ASCII/字段名单或独立长度限制。原始输入和完整事件沿用总 32 KiB，队列为 128 条/512 KiB。字符串属性复用既有敏感文本清理，事件以不可变快照处理；不打印输入。iOS 宿主 redactText 仍在监控线程执行，真正 JSON 编码预算和 Provider 交付也留在该线程。

业务 admission 先预计算最旧 performance/resource 能否腾足空间，足额后才执行删除和 append，否则零删除拒绝；业务不挤已有业务、加载、生命周期或异常事件。系统淘汰顺序为 performance/resource→business→原有兜底。关闭前入队快照保留旧身份可晚排出，关闭后新调用拒绝；同 View reload 沿原 exact_view 降级，不按最新 Bundle 猜归属。

三端 Provider 接口继续使用 `record(event)`，LocalDiagnostic 仍只本地记录。首次需要监控的 View 创建前由宿主安装 Provider，声明并实际处理 business.event；厂商 SDK/后台尚未接入。此扩展完成源码接线，本轮没有编译、测试或设备调用证明。
Playground 的媒体方法由 Android / iOS 手写宿主实现；HarmonyOS 已导出同名方法，但当前明确返回
`1004`“尚未接入”，不伪造系统 Picker 或上传下载成功。

Android/iOS 的高级导航、直接 NativeModules 调用、launch mode、页面结果、恢复和
业务宿主接线见 [NAVIGATION_README.md](NAVIGATION_README.md)。HarmonyOS 也导出这组
高级栈 API；其栈元数据由 `LynxNavigator` 维护并映射到 ArkUI Router，转场状态为明确的
Router 降级态。

## Android / iOS OTA 业务健康

```ts
markOtaHealthy(callback: (result: {
  code: number
  message: string
  data?: { confirmed?: boolean; releaseId?: string; reason?: 'not_candidate' }
}) => void): void
```

业务必要初始化完成后，由后台 JS 调用。容器将调用绑定到真实来源 LynxView、加载代次和
身份 epoch；实际 SDK 首屏与业务信号都到达后，才确认本地候选。此接口与只负责转场的
`markTransitionReady` 分开。成功 `code=0`；普通 current/Direct 返回
`confirmed=false, reason="not_candidate"`，本页已经确认后的重复调用可幂等返回 true。
来源失效或加载错误取消确认返回 1002，在途重复确认返回 1006；Runtime/Store 确认失败
双端均返回 1003 并保留原因。失败时 data
可省略或为空对象，只有 code=0 的健康结果保证 confirmed。package facade 成功 Promise 返回 data，
失败抛出保留原生 code 的 ShellNavigationError。
旧宿主无此方法时，模板自动声明先探测方法；显式 package facade 调用返回 1004。
Harmony 本轮未新增此入口。用例、平台契约与运行证据见 `docs/native-readiness-v1/`。

## App 语言

三端宿主统一支持 `zh-CN` 和 `en-US`。语言是 App 级状态，可以独立于系统语言：首次启动
按系统语言选择，系统不是中文或英文时回退 `zh-CN`；用户选择后保存 App 覆盖值，直到宿主
显式清除覆盖。RTL 本批次不支持，状态中的 `direction` 固定为 `ltr`。

```ts
setLocale(locale: 'zh-CN' | 'en-US' | null, callback: Callback): void
getLocale(callback: Callback): void
```

- `null`（HarmonyOS/跨语言调用也可传 `system`）清除 App 覆盖并恢复跟随系统；成功码仍是原始 Module 的 `code=0`；
- `data.state` 是带 `revision` 的完整状态，包含 `locale`、`language`、`systemLocale`、
  `appLocale`/`appLocaleOverride`、`source` 和 `direction`；
- 宿主先更新所有存活 LynxView 的完整 GlobalProps，再发送保留事件
  `lynxShellLocaleChanged`；业务不得通过通用 `broadcast` 伪造该事件；
- 新页面的 `GlobalProps.queryItems.locale` 和 Playground 的导航 wrapper 会携带当前
  canonical locale，业务页面不需要逐页拼接语言参数；
- 每个 Lynx Bundle 都是独立 JavaScript runtime，翻译资源和 i18next 实例由 Bundle 自己
  管理。宿主只提供状态同步，不把资源加载完成伪装成 `setLocale` 成功。

## 窗口与折叠屏环境

三端在 Lynx 4.0 页面创建时注入 `__lynxShellLayout` 和兼容 flat 字段
`screenWidth/screenHeight`、`viewportWidth/viewportHeight`、`safeAreaInsets`、
`orientation`、`windowMode`、`layoutRevision`。`screen` 表示当前 Window/Scene，
`viewport` 表示具体 LynxView 的可用区域；页面收到窗口、旋转、分屏或安全区变化后，宿主
原位调用 Lynx 4.0 的 screen metrics 和 viewport 更新 API，并发送
`lynxShellLayoutChanged`。

折叠状态、显示模式、角度和折痕只有在当前平台官方 API 明确可用时才出现在 `fold`；没有
真实数据时返回 capability `unknown`/`unavailable`，不生成伪造的双栏布局。HarmonyOS
共享元素转场和业务双栏布局继续延期。

## open

```ts
open(url: string, optionsJSON: string, callback: (result: NativeResult) => void): void
```

- `url`：支持本地 Bundle、HTTPS、`lynxshell://open`、`lynx://open`、`hybrid://lynxview_page` 与 Explorer 地址；
- `optionsJSON`：JSON Object，可包含 `title`、`fullscreen`、`orientation`、`backgroundColor`、`initData`、`globalProps` 等；
- callback：`{ code: number, message: string }`。

错误码：

| code | 含义 |
|---:|---|
| `0` | 已提交原生打开动作 |
| `1001` | URL 或 options 非法 |
| `1002` | 宿主导航器不可用 / 页面不可关闭 |
| `1500` | 原生异常 |

## close

```ts
close(callback: (result: NativeResult) => void): void
```

- Android：结束当前 Lynx Activity；
- iOS：优先 pop 当前控制器；根控制器不返回假关闭；
- HarmonyOS：通过 ArkUI Router 返回上一页。

## Android / iOS 高级导航

```ts
back(delta: number, optionsJSON: string, callback: Callback): void
popTo(routeKey: string, callback: Callback): void
popToWithOptions(routeKey: string, optionsJSON: string, callback: Callback): void
closeAll(callback: Callback): void
closeAllWithOptions(optionsJSON: string, callback: Callback): void
reLaunch(optionsJSON: string, callback: Callback): void
redirect(url: string, optionsJSON: string, callback: Callback): void
getNavigationState(callback: Callback): void
setBackGestureEnabled(enabled: boolean, callback: Callback): void
closeWithResult(resultJSON: string, callback: Callback): void
consumeNavigationResult(callback: Callback): void
prepareRoute(url: string, optionsJSON: string, callback: Callback): void
cancelPreparedRoute(token: string, callback: Callback): void
markTransitionReady(transactionID: string, callback: Callback): void
getTransitionState(callback: Callback): void
```

- 原始 Module 以 `code=0` 表示成功；Playground wrapper 归一化为 `code=1`，并把
  宿主原始错误码保存在 `nativeCode`；
- `back(delta)` 不越过当前 Lynx session 首页；
- `popTo` 找不到 routeKey 返回 `1003`，不会新开目标；
- `closeAll` 返回当前 session 进入前的宿主页；
- `reLaunch` 必须由业务宿主注入 Home Handler；
- `setBackGestureEnabled` 原位更新当前调用页的返回策略，不重建 LynxView；成功 data 为 `{backGestureEnabled, affectedCount: 1}`；
- 页面结果按目标 entryID 保存，并且只能消费一次；
- 回调只代表原生导航事务已执行/提交，不代表 Lynx 首帧完成。

### 动态返回策略

`setBackGestureEnabled` 与开页 `backGestureEnabled` 使用同一语义：Android 同时控制系统返回键和返回手势，iOS 控制壳管理的侧滑/自定义返回手势，显式 `back/close` 保留。`true` 仍受栈深度和既有 `popGesture.enabled` 约束；iOS 系统 Sheet 下拉关闭继续由 `barrierDismissible` 控制。

调用方 LynxView 必须属于当前栈顶容器；过期 Module、被覆盖页面和不受壳管理的容器返回 `1002`。原生转场或交互返回尚未收口时返回 `1006`，不排队、不提前写状态；可等待转场终态后重新调用。iOS 宿主启用 `setHostManagedBackGesture(true)` 时返回 `1004`，不回假成功。Android 将新值同步到页面请求/Intent，iOS 同步页面请求/Scene 导航快照，重建和恢复继续使用最新策略。

### Android callback 编码约束

Lynx 4.0 Android 的 `Callback.invoke(Object...)` 不会把任意 `HashMap` 自动变成 JS
Object。对象型结果必须先转成 `JavaOnlyMap`，数组必须是 `JavaOnlyArray`。当前
`LynxShellModule` 与 `ShellMediaBridge` 统一使用：

```kotlin
callback.invoke(Arguments.makeNativeMap(result))
```

`Arguments.makeNativeMap` 会递归处理嵌套 Map/List。不要改回
`callback.invoke(hashMapOf(...))`，否则真机会报
`unsupported type class java.util.HashMap contained in JavaOnlyArray`，页面 callback
收到 `null`。

`open` 的 `optionsJSON` 支持：

```json
{
  "launchMode": "push | singleTop | clearTop | singleTask",
  "animated": true,
  "backGestureEnabled": true,
  "deduplicate": true,
  "deduplicateWindowMs": 350,
  "routeType": "wx://bottom-sheet",
  "routeOptions": {
    "round": true,
    "height": 60
  },
  "routeConfig": {
    "transitionDuration": 300,
    "reverseTransitionDuration": 300,
    "barrierColor": "#66000000",
    "barrierDismissible": true,
    "fullscreenDrag": false,
    "popGestureDirection": "vertical"
  },
  "transition": {
    "style": "sharedElement",
    "fallbackStyle": "fade",
    "durationMs": 300,
    "readyTimeoutMs": 500,
    "sharedElements": [
      {
        "key": "hero",
        "sourceSelector": "hero-source",
        "targetSelector": "hero-target",
        "transitionOnGesture": true,
        "shuttleOnPush": "to",
        "shuttleOnPop": "to",
        "rectTweenType": "materialRectArc"
      }
    ]
  }
}
```

路由拦截不在当前协议范围内。

四个转场扩展方法仍由 Android/iOS 手写 Module 导出，不经过 autolink。页面只提供
selector/key 和一次性 ready，原生负责几何、首帧、多元素 overlay、progress 与
取消。路由提交后发送 `onRouteDone`；手势取消不发送它。完成、降级、取消和失败都
另发壳级 `onTransitionSettled`。显式 `routeType`、显式 `transition` 或
`animated=false` 的
push/pop/fallback 均由壳动画器独占，不再叠加系统导航动画。完整协议及
`prepareRoute` 与 Skyline preset-route 的边界见
[TRANSITIONS_README.md](TRANSITIONS_README.md)。

普通 NativeModules 不能同步执行 Skyline `worklet:on-frame`，也不能传递
`withOpenContainer` 运行时实例。本协议完整实现的是冻结后的原生声明式字段与内置
曲线；任意每帧 JS、任意 `routeBuilder` 仍不在本协议范围内。

## storage

```ts
setStorageItem(key: string, value: string): void
getStorageItem(key: string, callback: (value: string) => void): void
removeStorageItem(key: string): void
clearStorage(): void
```

平台隔离存储：

- Android：专用 `SharedPreferences`；
- iOS：固定前缀的 `UserDefaults` Key；
- HarmonyOS：专用 Preferences Name，使用同步写入与 `flushSync`。

业务接入时应继续限制 Key 长度、敏感数据类型和存储容量。不要把令牌、支付密钥等高敏感数据作为普通页面存储。

## Router OTA 磁盘清理扩展

以下方法是 Android/iOS `LynxShellModule` 的可选扩展；HarmonyOS 当前通过宿主
`LynxRouter.deleteOtaBundles/deleteAllOtaBundles` 提供同等能力，暂不把它们伪装成
Harmony NativeModule 方法。页面应使用可选调用并检查回调 `code`：

```ts
deleteOtaBundles?: (
  lynxAppId: string,
  callback: (result: NativeResult<{ lynxAppId: string; deleted: boolean }>) => void
) => void
deleteAllOtaBundles?: (
  callback: (result: NativeResult<{ scope: 'all'; deleted: boolean }>) => void
) => void
```

`code === 0` 表示磁盘内容已经直接删除；不会生成 `.delete-*`、`.legacy-*` 或其它备份
目录，App 内置 Bundle 不受影响。`1001` 表示参数错误，`1004` 表示目标平台尚未安装
Router OTA runtime，`1500` 表示文件系统删除失败。

## getAppInfo

```ts
getAppInfo(callback: (info: AppInfo) => void): void
```

返回稳定字段：

```json
{
  "platform": "android | ios | harmony",
  "appVersion": "1.0.0",
  "buildNumber": "1",
  "systemVersion": "..."
}
```

## Android / iOS Playground 媒体能力

```ts
chooseMedia(optionsJSON: string, callback: (result: MediaResult) => void): void
uploadFile(optionsJSON: string, callback: (result: MediaResult) => void): void
uploadImage(optionsJSON: string, callback: (result: MediaResult) => void): void
downloadFile(optionsJSON: string, callback: (result: MediaResult) => void): void
saveDataURL(optionsJSON: string, callback: (result: MediaResult) => void): void
```

- Android：系统 `ACTION_OPEN_DOCUMENT` / 相机 Intent、OkHttp、App cache；
- iOS：`UIImagePickerController`、`URLSession`、temporary directory；
- 两端均直接挂在 `NativeModules.LynxShellModule`，不经过 Sparkling autolink；
- 下载、Data URL 和所选单文件均限制为 20 MB；
- 成功回调为 `{ code: 0, msg: "ok", data: ... }`，失败为 `{ code: -1, msg }`。

## HarmonyOS 异步语义

HarmonyOS 当前实现是普通 Module，没有加 `@Sendable`。普通 Module 方法按 Lynx Harmony 的异步 Module 语义执行，需要结果的方法全部通过 callback 返回；存储写入方法本身不依赖 JS 返回值。Entry 模块仅兼容导出 HAR 的 Module，避免两份实现漂移。

## LynxCapacitor 三端语义契约 v1.1

Android、iOS、HarmonyOS 的自有 LynxCapacitorModule 以 Android
NativeCapabilityCatalog 为事实源，冻结 40 个能力域、146 个方法、方法顺序和
rtype: promise。三端在进入具体平台 adapter 前都执行相同的目录闸门：

1. 未知 pluginId 或目录外 methodName 返回 UNIMPLEMENTED；
2. 目录内但不在该平台 implementedMethods 的方法返回 UNSUPPORTED；
3. 只有通过闸门后才进入权限、UI、网络、文件、传感器或宿主 Provider。

getPluginHeaders() 保持旧形状；getCapabilityStatus() 在保留 state、methods
和 implementedMethods 的基础上增加 contractVersion、semanticState、reasonCode、
reason、methodStatus 和 verification。页面分支必须读取稳定的 semanticState/reasonCode，
不能解析自然语言 reason。普通 callback、错误 callback、listener 和长任务进度都保留
callbackId/pluginId/methodName/success/save 身份字段；需要 Lynx 保留的事件使用
save: true，listener 使用 listenerId，长任务使用 operationId。

payload 的 callbackId 缺失或为 null 时统一为 "-1"，显式空值或非字符串返回
INVALID_ARGUMENT；pluginId、methodName 必须是非空字符串；options 缺失或为 null
时视为空对象，其他非对象返回 INVALID_ARGUMENT。错误在原有 error.code 和
error.message 之外增加稳定 error.reasonCode。

完整字段、错误码、平台差异和验证层级见
[docs/lynx-capacitor-semantics-v1/README.md](docs/lynx-capacitor-semantics-v1/README.md)；
机器可读目录见
[semantic-catalog.json](docs/lynx-capacitor-semantics-v1/semantic-catalog.json)；
静态检查命令为 python3 scripts/verify_lynx_capacitor_semantics.py。

三端默认 Demo 已完成独立能力模块的依赖、注册、权限及必要生命周期源码接线；
verification.host 为 `configured_not_run`，build/device 保持 `not_run`，不代表全部能力已验收。
接线方式与剩余平台 owner/provider 边界见 [Demo 接入说明](CAPACITOR_DEMO_INTEGRATION.md)。

## 页面侧声明

Android/iOS 见 `examples/lynx-shell-module.d.ts`；HarmonyOS 基础接口见
`examples/lynx-shell-module.harmony.d.ts`。完整导航说明见
[NAVIGATION_README.md](NAVIGATION_README.md)。


## Android / iOS 统一原生媒体接线

旧 Shell 五个媒体方法保留 optionsJSON 与 code/msg/data ABI，底层经宿主中性 SPI 连接 Cap。
Android 首个 View 前安装 LynxShell.installNativeMediaHost；iOS bootstrap 前安装
LynxRouter.installMediaHandler，并继续注册 Cap 的 onViewDestroy。未装 handler 的旧 Shell
调用返回 code=-1；没有无界旧实现 fallback。Cap 四 transport 与40域146方法不变。

图库选择的 mediaType0/1/2 是图片/视频/混合，最多16项；新 public NativeMedia API 默认单选。
视频预览用原生播放器；NativeMedia 图片预览用 Android 内置原生图片 Activity / iOS Quick Look。
Camera.chooseFromGallery 的 source 缺省 PHOTOS，可选 CAMERA / PROMPT；纯类型 CAMERA 直接
拍照或录像，mixed CAMERA 提供拍照/录像选择，PROMPT 增加相册入口。选择拍摄后才申请
相机及必要麦克风权限；参数支持 cameraDirection/saveToGallery/includeMicrophone 和
promptLabelHeader/Photos/TakePhoto/RecordVideo/Cancel。getPhoto 的显式 PROMPT 同样显示来源菜单。
选择结果保持 Android results / iOS photos；capture 每次一项。iOS 不支持静音录像，只有实际
选择录像后才返回 UNSUPPORTED，不妨碍来源菜单里的相册选择。
FileViewer.openDocumentFromLocalPath 新增互斥 items（1...16 个本地图片位置）+ initialIndex
（缺省0且必须为合法整数）参数；图片列表按顺序左右切换，回执 opened/uri/itemCount/initialIndex。
旧 single 文档参数继续使用系统文档 handler。NativeMedia.previewImage/previewImages 使用图片
列表入口，Android 不再依赖外部图片查看应用。图片与菜单绑定当前 Lynx owner，销毁时释放。
只接受合法本地 URI/应用文件；成功回执不表示完整播放或用户看完。平台的目录、文件
物化预算、原生音轨支持与结果字段分别写入 docs/native-media-v1/及公共包native-media文档。

最终媒体源码已构建安装并显示Demo/来源菜单；实际拍摄、多图手势与完整用例未验收。旧六项测试证据属于媒体改造前版本。
