# Lynx Android / iOS NativeModules 高级导航

本文是当前壳工程的导航与原生交互接入手册。实现直接使用 Lynx 4.0 官方
`NativeModules`，Android/iOS 都由宿主手写 `LynxShellModule`，不依赖
`sparkling-method`、`spkPipe`、autolink 或 codegen。

本阶段没有实现路由拦截、登录鉴权和异步路由放行。HarmonyOS 已补齐与 Playground
一致的导航方法并映射到 ArkUI Router；共享元素转场仍返回明确的降级状态，媒体/文件桥
则返回 `1004` 未接入。

## 1. 架构

```text
ReactLynx 页面
  └─ playground/src/lib/navigation.ts
       └─ NativeModules.LynxShellModule
            ├─ Android LynxShellModule.kt
            │    └─ LynxNavigator
            │         ├─ Activity session/entry 注册表
            │         ├─ SharedPreferences 页面结果
            │         └─ AppHomeHandler / SessionExitHandler
            └─ iOS LynxShellModule.swift
                 └─ ShellNavigator
                      ├─ UINavigationController session/entry
                      ├─ UserDefaults 页面结果/恢复快照
                      └─ ShellAppHomeHandler
            └─ HarmonyOS LynxShellModule.ets（HAR）
                 └─ LynxNavigator
                      ├─ ArkUI Router
                      └─ 进程内 session/entry/routeKey 注册表
```

职责边界：

- Module：参数解析、主线程切换、结果封装；
- Navigator：launch mode、回退、清栈、结果、恢复和防重复；
- Container：LynxView 生命周期、页面展示参数、系统返回手势；
- TypeScript wrapper：类型安全、URL 组装、成功码归一化；
- 业务宿主：真实 TabBar、混合原生栈和 App Router 接线。

## 2. 导航身份

每个原生 Lynx 页面包含四个关键字段：

| 字段 | 含义 |
|---|---|
| `sessionID` | 一次从原生宿主页进入后形成的 Lynx 页面会话 |
| `entryID` | 某个页面实例的唯一标识 |
| `routeKey` | 业务可稳定定位的逻辑页面标识 |
| `order` | entry 在当前 session 内的顺序 |

`routeKey` 应由业务显式提供。未提供时使用规范化 Bundle URL，只适合作为兜底。

宿主锚点是当前 session 第一个 Lynx 页面之前的原生页面。所有批量操作都限定在当前
session；Android 不调用 `finishAffinity()`，iOS 不替换未知业务 App 的 window root。

## 3. 推荐：通过 TypeScript wrapper 调用

```ts
import {
  navigate,
  open,
  close,
  back,
  popTo,
  closeAll,
  reLaunch,
  redirect,
  getNavigationState,
  closeWithResult,
  consumeNavigationResult,
  prepareRoute,
  cancelPreparedRoute,
  markTransitionReady,
  getTransitionState,
  navigateWithPreset,
  navigateSharedElement,
  navigateOpenContainer,
} from './lib/navigation.js'
```

wrapper 的结果约定：

```ts
interface NavigateResponse<T = unknown> {
  code: number // 1 成功，0 失败
  msg?: string
  data?: T
}
```

注意：这是 Playground wrapper 的兼容约定。直接调用原生 Module 时，原始协议是
`code === 0` 成功，非 0 失败。

共享元素、Open Container、Skyline routeType、Bundle 预取和跟手返回属于同一导航
入口上的原生转场扩展，详见 [TRANSITIONS_README.md](TRANSITIONS_README.md)。

业务转场不要从完整 JSON 起步，优先使用：

```ts
navigateWithPreset({ bundle: 'detail.lynx.bundle', preset: 'zoom' })
navigateSharedElement({ bundle: 'detail.lynx.bundle', source: 'hero-a', target: 'hero-b' })
navigateOpenContainer({ bundle: 'detail.lynx.bundle', source: 'card-a' })
```

### 3.1 普通 push

```ts
navigate({
  path: 'order-detail.lynx.bundle',
  options: {
    routeKey: 'order-detail-10001',
    launchMode: 'push',
    params: {
      order_id: '10001',
      title: '订单详情',
    },
  },
}, (result) => {
  if (result.code !== 1) {
    console.log(result.msg)
  }
})
```

### 3.2 四种 launch mode

```ts
type LaunchMode = 'push' | 'singleTop' | 'clearTop' | 'singleTask'
```

| launchMode | routeKey 已存在时的结果 |
|---|---|
| `push` | 始终新增一个实例 |
| `singleTop` | 只有栈顶同 key 时原位刷新，否则 push |
| `clearTop` | 移除目标之上的页面，保留目标旧参数 |
| `singleTask` | 移除目标之上的页面，并用新参数刷新目标 |

示例：

```ts
navigate({
  path: 'home.lynx.bundle',
  options: {
    routeKey: 'lynx-home',
    launchMode: 'clearTop',
  },
})
```

### 3.3 关闭与 delta 回退

```ts
// 关闭当前容器；session 首页也可以返回原生宿主页。
close()

// 当前 Lynx session 内回退两页；深度不足时收敛到 session 首页。
back(2, { animated: true }, (result) => {
  console.log(result.msg)
})
```

`back(delta)` 不越过 session 首页。若要关闭 session 首页，使用 `close()`、
`closeAll()` 或 `reLaunch()`。

### 3.4 A-B-C-D-E 回到已有 A

```ts
popTo('nav-chain-A', { animated: true }, (result) => {
  console.log(result.data?.affectedCount)
})
```

找不到目标时返回 `1003`，不会退化为重新打开 A。

### 3.5 关闭全部 Lynx 页面，回到进入前页面

```ts
closeAll({ animated: true }, (result) => {
  console.log(result.msg)
})
```

- iOS：移除当前 session 起的导航栈后缀，连同其中穿插的原生页面一起返回锚点；
- Android：默认结束当前 session 已登记的 Lynx Activity。连续 Lynx 栈可直接工作；
  若业务允许中间插入原生 Activity，应接入 `SessionExitHandler`。

### 3.6 返回 App 主页面 / TabBar

```ts
reLaunch({
  tab: 'home',
  source: 'order-detail',
  animated: false,
}, (result) => {
  console.log(result.msg)
})
```

通用壳不知道业务 TabBar，必须由 Android `AppHomeHandler` 或 iOS
`ShellAppHomeHandler` 接入。未安装时返回 `1004`，不会猜测主页。

### 3.7 当前页重定向

```ts
redirect({
  path: 'page-a.lynx.bundle',
  options: {
    routeKey: 'page-a',
    params: { source: 'redirect' },
  },
})
```

`A-B-C` 在 C 执行后得到 `A-B-A`。当前 entry 的 `sessionID`、`entryID` 和 `order`
不变，只重新加载 Bundle 和页面参数。

### 3.8 查询真实原生栈

```ts
getNavigationState((result) => {
  if (result.code !== 1 || !result.data) return

  console.log(result.data.current.routeKey)
  console.log(result.data.stack)
  console.log(result.data.depth)
  console.log(result.data.canGoBack)
})
```

数据结构：

```ts
interface NavigationState {
  sessionID: string
  current: {
    entryID: string
    routeKey: string
    index: number
  }
  stack: Array<{
    entryID: string
    routeKey: string
    index: number
  }>
  depth: number
  canGoBack: boolean
  hasHostAnchor: boolean
  affectedCount: number
}
```

`canGoBack` 只表示当前 Lynx session 内是否有上一页，不把原生宿主页计算进去。

### 3.9 页面返回结果

子页：

```ts
closeWithResult({
  action: 'selected',
  itemID: '10001',
}, (result) => {
  console.log(result.msg)
})
```

目标页：

```ts
consumeNavigationResult((result) => {
  if (!result.data?.hasResult) return
  console.log(result.data.result)
  console.log(result.data.sourceRouteKey)
})
```

结果规则：

- 只接受 JSON Object；
- 结果绑定目标 `entryID`，不依赖跨页面 JS callback 闭包；
- 每个目标 entry 同时只保留一条待消费结果，新结果会覆盖旧结果；
- 一次读取后删除；
- Android Activity 重建、iOS Scene 恢复后仍可读取；
- 页面应在自己的 appear/resume 语义中主动调用消费方法。

## 4. 直接调用 NativeModules

如果业务不使用当前 TypeScript wrapper，可以直接调用官方全局对象：

```ts
NativeModules.LynxShellModule.open(
  'hybrid://lynxview_page?bundle=page-b.lynx.bundle&route_key=page-b',
  JSON.stringify({
    routeKey: 'page-b',
    launchMode: 'push',
    animated: true,
    backGestureEnabled: true,
  }),
  (result) => {
    // 直接调用 Module：code === 0 才是成功。
    console.log(result.code, result.message, result.data)
  },
)
```

完整原始 Module 签名：

```ts
interface LynxShellModule {
  open(route: string, optionsJSON: string, callback: Callback): void
  close(callback: Callback): void
  back(delta: number, optionsJSON: string, callback: Callback): void

  popTo(routeKey: string, callback: Callback): void
  popToWithOptions(routeKey: string, optionsJSON: string, callback: Callback): void

  closeAll(callback: Callback): void
  closeAllWithOptions(optionsJSON: string, callback: Callback): void

  reLaunch(optionsJSON: string, callback: Callback): void
  redirect(route: string, optionsJSON: string, callback: Callback): void

  getNavigationState(callback: Callback): void
  closeWithResult(resultJSON: string, callback: Callback): void
  consumeNavigationResult(callback: Callback): void
}
```

兼容方法 `popTo/closeAll` 保留旧签名；需要动画、结果或防重复选项时使用
`popToWithOptions/closeAllWithOptions`。

## 5. optionsJSON

导航字段：

```json
{
  "launchMode": "push",
  "animated": true,
  "backGestureEnabled": true,
  "deduplicate": true,
  "deduplicateWindowMs": 350,
  "result": {
    "key": "value"
  }
}
```

页面字段可与导航字段共存：

```json
{
  "routeKey": "order-detail-10001",
  "title": "订单详情",
  "initData": {},
  "globalProps": {},
  "fullscreen": false,
  "showNavigationBar": true,
  "hideStatusBar": false,
  "orientation": "portrait",
  "backgroundColor": "#FFFFFF"
}
```

`deduplicateWindowMs` 范围为 0 到 5000。默认在 350ms 内抑制重复或转场重入，
返回 `1006`。设为 0 或 `deduplicate=false` 可关闭时间窗抑制，但 iOS 仍会拒绝
正在执行 UIKit transition 时的栈重入。

成功回调只表示原生导航事务已执行或提交，不表示 Lynx Bundle 已下载、解析或完成首帧。

## 6. Android 宿主接入

### 6.1 Module 注册

当前工程已在 Runtime 初始化阶段显式注册：

```kotlin
LynxEnv.inst().registerModule(
    LynxShellModule.MODULE_NAME,
    LynxShellModule::class.java,
)
```

页面侧名称必须与 `MODULE_NAME = "LynxShellModule"` 一致。

### 6.2 返回 App 主页面

```kotlin
LynxNavigator.installAppHomeHandler(
    AppHomeHandler { activity, optionsJson ->
        activity.startActivity(
            Intent(activity, MainTabActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        )
        true
    },
)
```

生产代码可以解析 `optionsJson` 后选择目标 Tab。Handler 返回 false 表示拒绝跳转。

### 6.3 混合原生 / Lynx session

如果允许 `Lynx A -> 原生 X -> Lynx B`，默认 Activity 弱引用注册表无法枚举未知业务
Activity。应由业务 Router 接入：

```kotlin
LynxNavigator.installSessionExitHandler(
    SessionExitHandler { activity, sessionID ->
        appRouter.returnToLynxSessionAnchor(activity, sessionID)
        true
    },
)
```

Handler 负责精确返回最初锚点；Navigator 随后只 finish 当前 session 的 Lynx Activity。

### 6.4 Activity 重建

Navigator 把 `sessionID`、`entryID`、`parentEntryID`、`order` 写入 Intent。系统因配置
变化或进程恢复重建 Activity 时复用这些字段，注册表按持久 order 排序，不依赖
`onCreate` 回调先后。

## 7. iOS 宿主接入

### 7.1 Module 注册

当前工程在 Lynx Runtime 配置中显式注册 Swift Module：

```objc
[config registerModule:LynxShellModule.class];
```

Swift 侧通过 `name` 和 `methodLookup` 明确维护 JS 方法名与 selector，不扫描 npm 包。

### 7.2 返回 App 主页面

```swift
ShellNavigator.shared.installAppHomeHandler { navigationController, options in
    guard let tabBarController = navigationController.tabBarController else {
        return false
    }
    tabBarController.selectedIndex = 0
    navigationController.popToRootViewController(animated: false)
    return true
}
```

真实业务如果每个 Tab 有独立 NavigationController，应在 Coordinator 中选择正确栈，
不要把 TabBar 结构硬编码到通用 Module。

### 7.3 Scene 恢复

当前壳只持久化 JSON 可序列化内容：

- request；
- sessionID；
- entryID；
- parentEntryID；
- order。

不会持久化 UIViewController、LynxView、Provider、Runtime 或 callback。恢复时重新创建
容器并重新执行 Bundle URL、安全策略、尺寸和颜色校验。快照非法时自动清除并回退
默认 Playground。

业务登出、账号切换或不希望恢复时可调用：

```swift
ShellNavigator.shared.clearSavedNavigationState()
```

## 8. 动画与系统返回

- `animated=true` 且未声明 `routeType/transition`：使用平台默认
  Activity/UINavigationController 转场；
- 声明 `routeType` 或非 `default` transition：打开、返回、手势和 fallback 全部由
  壳的自定义 coordinator 绘制，系统 Window/UIKit 默认动画被抑制；
- `animated=false`：Android 使用无动画 Activity flag，iOS 使用非动画 push/pop，HarmonyOS
  使用目标 Page 的零时长 `pageTransition`；
- `backGestureEnabled=true`：允许 iOS 侧滑和 Android 系统 Back；
- `backGestureEnabled=false`：系统返回被禁用，但原生导航栏返回和 Module API 保留。

所有手势都有按钮/Module 替代路径，避免页面不可退出。自定义转场的 Toolbar、
NativeModules 与系统返回最终进入同一个原生状态机，不会再补播第二段系统动画。

## 9. 用户提出的场景映射

| 场景 | API | 结果 |
|---|---|---|
| 普通跳转 | `navigate/open` + push | A -> A-B |
| 关闭当前页 | `close` | A-B -> A |
| A-B-C-D-E-A | `popTo("A")` 或 `clearTop(A)` | A-B-C-D-E -> A |
| 关闭 B/C/D/E 回 A | `popTo("A")` | 只保留已有 A |
| 关闭全部 Lynx 回进入前页面 | `closeAll` | Host-A-B-C -> Host |
| 返回 App TabBar 主页面 | `reLaunch` | 由 Home Handler 决定 |
| A-B-C，C 重定向 A | `redirect(A)` | A-B-A |
| 一次返回多层 | `back(delta)` | A-B-C-D -> A-B |
| 页面复用 | launch mode | singleTop/clearTop/singleTask |
| 查询导航状态 | `getNavigationState` | 返回真实原生 session 栈 |
| 子页返回数据 | `closeWithResult` | 父页一次性消费 |

## 10. 错误码

| code | 含义 |
|---:|---|
| `0` | 原始 Module 成功 |
| `1001` | URL、JSON、delta、launchMode 或 options 非法 |
| `1002` | 宿主导航器、当前容器或 entry 不可用 |
| `1003` | `popTo` 目标 routeKey 不存在 |
| `1004` | Home/Session Handler 未安装、拒绝或不可用 |
| `1005` | 当前 session 无可回退目标或没有宿主锚点 |
| `1006` | 重复导航或平台转场繁忙 |
| `1500` | 平台原生异常 |

## 11. Playground 验证入口

首页进入：

```text
导航栈 / nav-chain.lynx.bundle
```

页面可手动测试：

- A-B-C-D-E push；
- `back(2)`；
- `popTo(A)`；
- `singleTop(Current)`；
- `clearTop(A)`；
- `singleTask(A)`；
- `redirect(A)`；
- `getNavigationState()`；
- `closeWithResult()` / `consumeNavigationResult()`；
- `closeAll()`；
- `reLaunch(Home)`。

## 12. 当前验证边界

- Android Kotlin 编译已通过；
- iOS Simulator Debug compile-only build 已通过；
- TypeScript 已通过；
- 最终 Bundle、Android assembleDebug 和统一静态检查以本轮最终验收报告为准；
- iOS 没有重复执行真机/模拟器点击矩阵；
- Android 真机按钮矩阵由用户在最终 APK 上自行测试；
- 路由拦截明确未实现。

相关源码：

- `playground/src/lib/navigation.ts`
- `playground/src/pages/nav-chain/App.tsx`
- `android/lynx-shell/src/main/java/com/example/lynxshell/bridge/LynxShellModule.kt`
- `android/lynx-shell/src/main/java/com/example/lynxshell/routing/LynxNavigator.kt`
- `ios/LynxShellKit/Bridge/LynxShellModule.swift`
- `ios/LynxShellKit/Routing/ShellNavigator.swift`
