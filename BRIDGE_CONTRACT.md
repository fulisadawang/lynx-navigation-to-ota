# LynxShellModule 三端 Bridge 协议

模块名：`LynxShellModule`

- Android：`LynxModule` + `@LynxMethod`；
- iOS：`LynxModule.name` + `methodLookup`；
- HarmonyOS：ArkTS `LynxModule`，在 `LynxView.modules` 中注册。

基础 `open/close`、存储和 AppInfo 三端方法名保持一致，UI 导航动作必须进入平台
UI 线程/路由上下文。
Playground 的媒体方法由 Android / iOS 手写宿主实现；HarmonyOS 已导出同名方法，但当前明确返回
`1004`“尚未接入”，不伪造系统 Picker 或上传下载成功。

Android/iOS 的高级导航、直接 NativeModules 调用、launch mode、页面结果、恢复和
业务宿主接线见 [NAVIGATION_README.md](NAVIGATION_README.md)。HarmonyOS 也导出这组
高级栈 API；其栈元数据由 `LynxNavigator` 维护并映射到 ArkUI Router，转场状态为明确的
Router 降级态。

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
- 页面结果按目标 entryID 保存，并且只能消费一次；
- 回调只代表原生导航事务已执行/提交，不代表 Lynx 首帧完成。

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

## 页面侧声明

Android/iOS 见 `examples/lynx-shell-module.d.ts`；HarmonyOS 基础接口见
`examples/lynx-shell-module.harmony.d.ts`。完整导航说明见
[NAVIGATION_README.md](NAVIGATION_README.md)。
