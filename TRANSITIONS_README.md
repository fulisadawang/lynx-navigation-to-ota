# Lynx Android / iOS Skyline 风格原生容器转场

本文说明如何在“一页 Lynx 对应一个真实 Activity / UIViewController”的前提下，
迁移微信 Skyline 的 `preset-route`、`share-element` 与 `open-container` 公开可观察
语义。这里的“完成迁移”指七种内置预设、声明式共享元素、Open Container、正反向
转场、手势取消/完成和路由终态形成原生闭环；不把微信私有渲染树、任意 Worklet
执行器或 `OpenContainer` JS 实例伪装成 Lynx 已具备的同一运行时。

工程约束：

- Android 每个 Lynx 页面仍由独立 `LynxShellActivity` 承载；
- iOS 每个 Lynx 页面仍由独立 `LynxContainerViewController` 承载；
- 页面只通过手写 `NativeModules.LynxShellModule` 声明路由，不使用
  `sparkling-method`、autolink 或 codegen；
- 页面不上传 375/750 设计稿坐标，不用 JS 逐帧驱动原生页面；
- 几何测量、目标首帧、快照 overlay、动画进度、手势取消和最终栈提交都在原生主线程；
- 一旦声明自定义转场，打开、关闭、Toolbar Back、系统 Back/侧滑都只由自定义
  coordinator 绘制，不允许再叠加 Activity 或 UIKit 的系统默认动画。

## 1. 单一动画所有权

这是本实现最重要的规则：

```text
transition 未声明或 style=default
  └─ 平台系统导航动画拥有视觉控制权

routeType 已声明或 style!=default
  └─ 壳的自定义转场协调器拥有唯一视觉控制权
       ├─ push
       ├─ Toolbar / NativeModules pop
       ├─ Android Back 按键与系统返回手势
       ├─ iOS edge pan
       ├─ 手势 cancel / finish settle
       └─ fallback
```

显式自定义转场的 fallback 仍是壳自己绘制的 `fade / slide / none`，不能调用
Android `ActivityOptions.makeCustomAnimation`，也不能把 iOS 的交互返回重新交给系统
`interactivePopGestureRecognizer`。否则就会出现“自定义动画走完又执行一次系统动画”。

## 2. 页面侧最简 API

普通业务只需要三个入口：

```ts
import {
  navigateWithPreset,
  navigateSharedElement,
  navigateSharedElements,
  navigateOpenContainer,
} from './lib/navigation.js'
```

### 2.1 七种 Skyline 预设

```ts
navigateWithPreset({
  bundle: 'product-detail.lynx.bundle',
  preset: 'zoom',
})
```

完整预设与官方名称：

| 页面 preset | 原生 routeType |
|---|---|
| `bottomSheet` | `wx://bottom-sheet` |
| `heroSheet` | `wx://hero-sheet`（壳扩展，多档位 Sheet） |
| `up` / `upwards` | `wx://upwards` |
| `zoom` | `wx://zoom` |
| `cupertinoModal` | `wx://cupertino-modal` |
| `cupertinoModalInside` | `wx://cupertino-modal-inside` |
| `modalNavigation` | `wx://modal-navigation` |
| `modal` | `wx://modal` |

这七种不是同一个 slide 的别名。原生 renderer 分别处理半屏高度与圆角、上推、
中心缩放、外层 Cupertino 卡片、卡片内页、模态导航页和普通模态页。另有壳级
`fade / slide / none`，它们不属于 Skyline 七种 routeType。

进阶页面可覆盖 `routeConfig` 和 `routeOptions`：

```ts
navigateWithPreset({
  bundle: 'filter.lynx.bundle',
  preset: 'bottomSheet',
  routeOptions: {
    round: true,
    height: 60, // vh
  },
  routeConfig: {
    transitionDuration: 300,
    reverseTransitionDuration: 300,
    barrierColor: '#66000000',
    barrierDismissible: true,
    fullscreenDrag: false,
    popGestureDirection: 'vertical',
  },
})
```

普通页面不要重复填写这些参数，原生预设已有稳定默认值。

多档位 `heroSheet` 使用同一组 Sheet 参数；`detents` 必须严格递增，单位为 vh，最多
4 档。省略 `initialDetent` 时，`bottomSheet` 选择最大档，`heroSheet` 的默认配置为
`[28, 56, 92]` 并从 `56vh` 打开：

```ts
navigateWithPreset({
  bundle: 'product-detail.lynx.bundle',
  preset: 'heroSheet',
  routeOptions: {
    round: true,
    detents: [28, 56, 92],
    initialDetent: 56,
  },
})
```

### 2.2 Share Element：同 key 自动配对

来源页和目标页用同一个轻量包装：

```tsx
import { ShareElement } from './components/ShareElement/index.js'

<ShareElement shareKey="product-cover-10001" className="cover">
  <image className="image" src={coverURL} />
</ShareElement>
```

```css
.cover {
  width: 96px;
  height: 96px;
}

.image {
  width: 100%;
  height: 100%;
}
```

两页的子节点结构应尽量一致；需要跟随容器缩放的子节点使用百分比尺寸。
`ShareElement` 内部固定设置 `flatten={false}`，保证 wrapper 对应一个可测量、可隐藏的
真实 Lynx 原生渲染节点。不能依赖 `view` 默认扁平化，否则图片或文字可能被提升到
父节点，原生层隐藏共享元素时会留下重影。

单元素跳转：

```ts
navigateSharedElement({
  bundle: 'product-detail.lynx.bundle',
  key: 'product-cover-10001',
})
```

多元素跳转：

```ts
navigateSharedElements({
  bundle: 'product-detail.lynx.bundle',
  elements: [
    { key: 'product-cover-10001' },
    { key: 'product-title-10001', rectTweenType: 'linear' },
    { key: 'product-price-10001', rectTweenType: 'materialRectCenterArc' },
  ],
})
```

最多 8 个元素。调用方应按目标页面的 DOM DFS 顺序传数组；数组越靠后的元素在
overlay 中层级越高。当前 NativeModules 适配不会自动扫描整个 Lynx 组件树。
当前 Playground 使用封面、标题和价格三个元素：来源页是横向商品卡，目标页是带
大图、评分、商品信息、颜色选择和购买区的完整详情页。商品图以本地
`?inline` 资源编入 Bundle，iOS/Android 离线运行时也能稳定产生共享元素快照。

如果旧页面已经存在不同 id，也可继续传：

```ts
navigateSharedElement({
  bundle: 'product-detail.lynx.bundle',
  source: 'product-cover-source',
  target: 'product-cover-target',
})
```

### 2.3 Open Container：只传关闭态容器

```tsx
<view id="order-card-source" bindtap={openDetail}>
  <text>订单详情</text>
</view>
```

```ts
navigateOpenContainer({
  bundle: 'order-detail.lynx.bundle',
  source: 'order-card-source',
})
```

省略参数时严格使用官方默认值：

```text
closed-color       white
closed-elevation   0
closed-radius      0
middle-color       ''
open-color         white
open-elevation     0
open-radius        0
duration           300ms
transition-type    fade
```

进阶覆盖：

```ts
navigateOpenContainer({
  bundle: 'order-detail.lynx.bundle',
  source: 'order-card-source',
  container: {
    closedColor: '#FFFFFF',
    middleColor: '#EEF2FF',
    openColor: '#FFFFFF',
    closedCornerRadius: 20,
    openCornerRadius: 0,
    closedElevation: 6,
    openElevation: 0,
    transitionType: 'fadeThrough',
    transitionDuration: 360,
  },
})
```

它不是一张源卡片快照在整页之上简单放大。正确层级是一个逐帧改变 rect、圆角、颜色
和阴影的裁剪容器；容器内同时承载关闭态内容与目标页面内容，并按 `fade` 或
`fadeThrough` 切换。

双端统一接受 `white / black / transparent / darkgray / gray / lightgray / red /
green / blue / yellow / cyan / magenta`、`#RRGGBB`、`#RRGGBBAA`、`rgb()` 和
`rgba()`；非法颜色在 Module 参数校验阶段失败，不让两端静默显示成不同颜色。
`middleColor` 为空时直接在关闭色与打开色之间插值；只有 `fadeThrough` 会把非空
`middleColor` 作为中间色。

## 3. Share Element 声明式原生语义

底层 `NativeTransitionSpec.sharedElements` 支持：

```ts
interface SharedElementSpec {
  key: string
  sourceSelector: string
  targetSelector: string
  transitionOnGesture?: boolean       // 底层默认 false
  shuttleOnPush?: 'from' | 'to'       // 默认 to
  shuttleOnPop?: 'from' | 'to'        // 默认 to
  rectTweenType?:
    | 'materialRectArc'
    | 'materialRectCenterArc'
    | 'linear'
    | 'elasticIn' | 'elasticOut' | 'elasticInOut'
    | 'bounceIn' | 'bounceOut' | 'bounceInOut'
    | `cubic-bezier(${string})`
}
```

规则：

- 同一页面的 key 必须唯一；
- 两页相同 key 自动组成一对；
- 受 NativeModules 单次请求模型约束，shuttle/curve 等配置以路由请求 descriptor
  为准，不声称自动读取目标页组件属性；
- push 默认使用目标页飞跃物，pop 默认也使用目标页飞跃物；
- push 与 pop 的共享元素时长和页面路由时长一致；
- `materialRectArc` 默认使用 fast-out-slow-in 并按对角弧线插值；
- `materialRectCenterArc` 按中心点弧线插值；
- 其他枚举按对应曲线对 LTWH 插值；
- 目标元素必须在首屏存在、可见且尺寸非零，否则走壳内自定义 fallback；
- 原元素和目标元素在飞跃阶段隐藏，结束或取消时必须原样恢复；
- 手势 cancel 不修改最终栈，finish settle 到 100% 后才提交一次 pop。

`navigateSharedElement(s)` 是便捷 API，会默认打开共享元素的手势反向动画；直接使用
低层 `NativeTransitionSpec` 时仍遵循 Skyline 的 `transitionOnGesture=false` 默认值。

### 3.1 `on-frame` 的明确边界

Skyline 的 `on-frame` 是 UI 线程同步 Worklet：每一帧接收 `progress / direction /
begin / end / current`，还可以同步返回一个新的 Rect。普通异步 NativeModules 无法在
每一帧跨 JS 线程同步执行并拿回 Rect；强行这样做会造成帧阻塞，也违背当前“不引入
autolink / JSI / Worklet Runtime”的项目约束。

因此当前完整实现的是所有内置 `rect-tween-type` 与原生声明式参数，不伪造任意 JS
`on-frame`。如果以后必须允许业务执行任意每帧函数，需要单独引入 UI-thread Worklet
Runtime 或安全的原生声明式表达式协议，这不是增加一个普通 Module 方法能解决的。

## 4. Open Container 原生适配语义

底层字段：

```ts
interface OpenContainerSpec {
  sourceSelector: string
  closedColor?: string
  middleColor?: string
  openColor?: string
  closedCornerRadius?: number
  openCornerRadius?: number
  closedElevation?: number
  openElevation?: number
  transitionType?: 'fade' | 'fadeThrough'
  transitionDuration?: number
}
```

push：

1. 原生读取来源 Lynx 元素的 Window rect；
2. 无系统动画创建目标 Activity/VC，并等待目标 Lynx 首屏与 layout；
3. 在原生 transition container 中创建裁剪容器；
4. 容器从来源 rect 插值到目标原生页面可见区域；
5. 同一 progress 插值圆角、颜色、阴影和双层内容 alpha；
6. 完成后移除 overlay、恢复真实页面，只保留最终 Activity/VC。

pop 与其严格反向；跟手返回时由同一个 progress 驱动，取消后恢复目标页，完成后才
真正 `finish/popViewController`。

官方公开了打开态容器的属性与前向转场；反向 pop、跟手取消以及真实 Activity/VC
栈提交是本壳为保证双端可退出性补充的原生协议，不描述为微信内部实现细节。

## 5. Preset Route 与 heroSheet

七种官方 routeType 与壳扩展 `heroSheet` 都先归一化为原生
`ShellPresetRouteSpec`，再由 Android/iOS 各自的 renderer 绘制。`routeConfig` 支持：

```ts
interface SkylineRouteConfig {
  opaque?: boolean
  maintainState?: boolean
  transitionDuration?: number
  reverseTransitionDuration?: number
  barrierColor?: string
  barrierDismissible?: boolean
  barrierLabel?: string
  canTransitionTo?: boolean
  canTransitionFrom?: boolean
  allowEnterRouteSnapshotting?: boolean
  allowExitRouteSnapshotting?: boolean
  fullscreenDrag?: boolean
  popGestureDirection?: 'horizontal' | 'vertical' | 'multi'
}
```

`open` 还支持顶层 `transparent?: boolean`。它只把原生 VC/Activity 变成透明承载层；页面
是否从底部进入、如何移动和何时退出，仍由页面自己的动画 owner 决定。

`bottom-sheet` 默认采用 iOS Page Sheet 形态：`height=92vh`、`round=true`，并显示 grabber。
页面高度、屏幕安全区、状态栏和原生导航栏都由当前 Activity/VC 可见区域计算，不使用设计稿
坐标。

`hero-sheet` 保留 `detents=[28,56,100]`、初始 `56vh` 的跨端 routeOptions contract，
但它不是原生高度 Sheet：目标页由透明全屏 Activity/VC 承载，页面自身通过顶部 peek spacer
和 `scroll-view` 连续上移到状态栏下方。Lynx 自己控制 surface 的底部入场、顶部导航渐变、
下拉退出和取消回弹；原生只在退出动画完成后无动画移除承载层，来源页保持原位，不做缩放、
下移或“后退”遮罩。

`bottom-sheet` 仍可以传 `routeOptions.detents` 获得原生多档高度吸附；heroSheet 的上滑
不由原生 detent 手势消费，以免抢走 Lynx 页面滚动。内容在顶部时的下拉关闭由 Lynx
main-thread touch handler 跟手完成，不参与上滑内容滚动。

- iOS 15+ 直接使用 `UISheetPresentationController`。默认 92vh 映射 `.large()`；iOS 16+
  对显式较小高度使用 custom detent，iOS 15 回退 `.medium()`。圆角、来源页缩放、系统遮罩、
  下拉跟手、完成/取消曲线和程序化向下关闭全部由 UIKit 执行，不再叠加壳自定义 pop animator。
- iOS 的 `heroSheet` 使用普通全屏透明 VC；原生不执行 hero 位移和 dismiss pan，Lynx
  surface/`scroll-view` 控制底部入场、peek、连续上滑、顶部导航渐变和下拉退出。
  `bottomSheet` 才进入 `UISheetPresentationController`/iOS 13/14 fallback。
- Android 的 `heroSheet` 使用全屏透明 `liveContent`；原生不修改 hero 内容高度、不添加抓手、
  不缩放或下移来源页，纵向触摸直接交给 Lynx 页面。普通 `bottomSheet` 继续保留来源页
  `0.94` 缩放、下沉和 detent 速度投影。

需要区分 API 字段“已接收”与底层运行时是否能够 1:1 等价：

| 字段 | 本壳行为 |
|---|---|
| `transitionDuration / reverseTransitionDuration` | 原生 push/pop 精确使用，范围 `0..5000ms` |
| `opaque / barrier* / fullscreenDrag / popGestureDirection` | 由双端原生容器、遮罩与手势消费 |
| `canTransitionTo / canTransitionFrom` | 只控制相邻页面的 secondary 联动，不关闭当前页自己的 primary 动画 |
| `maintainState=false` | iOS 释放被覆盖页的 LynxView 并在返回时重建；Android 若无法安全释放 Activity 内容会报告平台边界 reason |
| `allow*RouteSnapshotting=false` | 普通页面可不用快照；跨 Activity/VC 的 share/open/透明半屏若必须依赖快照，会明确降级，不静默丢底图 |

`cupertino-modal-inside` 与 `modal-navigation` 当前迁移的是公开可观察的卡片几何、
遮罩、内部横向运动和返回手势；它们仍位于业务 App 的同一个原生导航栈，不虚构一套
微信内部的嵌套 route runtime。

## 6. `onRouteDone` 与壳终态事件

NativeModules 的 callback 只表示路由事务已接受，不代表动画结束。需要在路由真正
settle 后恢复状态时：

```ts
import { onRouteDone } from './lib/navigation.js'

const remove = onRouteDone((event) => {
  console.log(event.direction, event.status, event.transactionID)
})

// 页面销毁时
remove()
```

原生只在 push、非交互 pop、手势完成或降级后仍成功提交路由时发送一次
`GlobalEventEmitter.onRouteDone`，不会逐帧向 Lynx 发事件。

更准确的触发边界：

- `onRouteDone`：路由已经提交完成；手势取消不触发；
- `onTransitionSettled`：壳扩展，所有终态都触发，包含 `cancelled/failed`。

```ts
import { onTransitionSettled } from './lib/navigation.js'

const removeSettled = onTransitionSettled((event) => {
  if (event.status === 'cancelled') {
    // 页面仍停留在当前栈顶，可恢复临时交互状态。
  }
})
```

## 7. 首屏与降级

目标页面开始自定义转场前至少满足：

```text
Lynx onFirstScreen
AND Android 原生节点至少稳定 64ms
AND 下一次 ViewRoot 绘制帧已经到达
AND 目标 selector 可解析、可见、尺寸非零
```

Android 不能在收到 `onFirstScreen` 的同一调用栈里立即抓目标页快照。
`markTransitionReady` 可能比 `onFirstScreen` 更早到达，旧的 retry 队列会因此越过
`postOnAnimation`，把尚未绘制的目标 `LynxView` 抓成白图。当前实现使用独立的
`targetFrameReady` 硬门禁；未显式传参时 Android 默认动画时长为 `420ms`，
ready 超时为 `1000ms`。

`LynxViewClient.onReceivedError` 也会收到图片等子资源错误。首屏已经成立后，这类错误
只保留在页面自己的错误链路中，不再把整页 Share Element / Open Container 降级为
`target_not_ready`。只有首屏建立前的致命加载错误才会取消本次目标页转场。

异步内容稳定后可再发送一次：

```ts
markTransitionReady(transactionID)
```

常见 reason：

| reason | 行为 |
|---|---|
| `source_selector_missing` | 壳内自定义 fallback |
| `target_selector_missing` | 壳内自定义 fallback |
| `target_not_ready` | 首屏或原生绘制帧超时，走壳内自定义 fallback |
| `snapshot_unavailable` | 壳内自定义 fallback |
| `prepared_route_expired` | 普通 Provider 加载后继续 |
| `gesture_conflict_fallback` | 降级 edge 手势 |
| `reduce_motion` | 短 fade 或 none |
| `process_restore_no_transaction` | 无动画恢复真实页面 |

WebView、视频、Surface/Metal 或受保护内容不保证可生成高质量快照，但页面导航不能
因此失败。

## 8. 手势与返回提交

默认完成判定：

```text
finish = progress >= 0.42
      || (progress >= 0.12 && forwardVelocity >= 700 logical-px/s)
```

- gesture begin 只创建交互事务，不修改最终栈；
- changed 只更新原生 animator；
- cancel settle 回 0，恢复页面、共享元素、alpha、transform 和状态栏；
- finish settle 到 1，再提交一次 pop/finish；
- Android Predictive Back、兼容 edge gesture、Toolbar Back 和 Module `close/back`
  进入同一 coordinator；
- iOS 自定义 edge pan 与系统 interactive pop 互斥；
- `backGestureEnabled=false` 禁止手势，但 Toolbar 和 Module 关闭仍走同一自定义
  非交互返回动画。

Android 的 source Window 快照会先擦除共享元素，再由 overlay proxy 补回。pop 到
100% 并调用 `Activity.finish()` 后，proxy 与 source underlay 必须继续保留到当前
Window 销毁；如果提前移除，上一页 Surface 恢复前会出现一帧空图/空文字。当前
coordinator 只在 commit 失败或 Activity 没有进入 finishing 时立即清理，正常返回由
`onDestroy` 统一清理冻结尾帧。

## 9. 直接调用 NativeModules

不使用 wrapper 时：

```ts
NativeModules.LynxShellModule.open(
  'hybrid://lynxview_page?bundle=detail.lynx.bundle',
  JSON.stringify({
    routeType: 'wx://zoom',
    routeConfig: {
      transitionDuration: 300,
      reverseTransitionDuration: 300,
    },
  }),
  (result) => {
    // 原始 Module code === 0 表示事务已接受。
  },
)
```

多共享元素：

```ts
NativeModules.LynxShellModule.open(
  'hybrid://lynxview_page?bundle=detail.lynx.bundle',
  JSON.stringify({
    transition: {
      style: 'sharedElement',
      sharedElements: [
        {
          key: 'cover',
          sourceSelector: 'cover-source',
          targetSelector: 'cover-target',
          transitionOnGesture: true,
          shuttleOnPush: 'to',
          shuttleOnPop: 'to',
          rectTweenType: 'materialRectArc',
        },
      ],
    },
  }),
  () => {},
)
```

转场扩展方法仍全部由双端手写 Module 导出：

```ts
prepareRoute(url, optionsJSON, callback)
cancelPreparedRoute(token, callback)
markTransitionReady(transactionID, callback)
getTransitionState(callback)
```

## 10. 与高级栈导航的关系

- 普通 push 支持全部转场；
- 相邻页 pop 可反向执行 share/open/preset；
- `singleTop` 原位刷新不伪造跨页元素；
- `clearTop / singleTask / back(delta>1) / popTo / closeAll` 先确定最终目标，再由一段
  自定义页面转场关闭中间页，不播放每一层系统动画；
- `redirect` 是当前 entry 原位替换，不创建虚假的跨页共享元素；
- 手势 cancel 不消费页面结果，不改变最终 navigation state；
- `animated=false` 强制 `effectiveTransition=none`。

栈语义见 [NAVIGATION_README.md](NAVIGATION_README.md)。

## 11. Playground

首页进入“原生容器转场”：

```text
transition-gallery.lynx.bundle
  └─ transition-detail.lynx.bundle
```

演示页包含：

- 丰富商品卡 → 商品详情，封面、标题、价格三个 share-element 同时飞跃；
- 三个共享元素在 pop 时沿 push 的同一 progress 和几何轨迹反向返回；
- 本地内联商品图，断网时也能体验完整效果；
- Open Container；
- 七种 Skyline routeType；
- fade / slide / none；
- Bundle prepare/open/cancel；
- 首屏 ready、状态查询和 `onRouteDone`；
- edge 返回的完成与取消。

## 12. 验收边界

构建通过只证明协议与原生代码可编译，不能单独证明动画视觉质量。本轮 iOS 在 iPhone
16 Pro Simulator 运行并确认透明 hero 的来源页快照；Android 在 OnePlus 8 / Android 13
真机确认 hero 的底部入场、来源页固定、Lynx 上滑到全屏、状态栏导航渐变，以及普通 fade
恢复 source snapshot 后不再白闪。其它高级转场仍按下表区分代码/构建证据与完整设备矩阵。

已验证：

- `pnpm exec tsc --noEmit`；
- 16 个 Lynx Bundle 构建；
- Android `:app:assembleDebug`；
- iOS Simulator Debug 构建、安装和运行；
- Share Element、Open Container、七种 routeType 的代码路径和协议静态检查；
- Android 默认全屏、无 Material Toolbar、状态栏 Window fullscreen；
- Android 对象型 NativeModule callback 不再返回 `null`，转场状态可读；
- Android hero 与普通 fade 的真机运行态；
- Android/iOS/HarmonyOS 静态回归。

仍需用户真机验收：

- Android 三键导航和 Android 14+ Predictive Back；
- Share Element、Open Container、其它 routeType 的最新真机视觉回归；
- iOS 真机 edge pan 完成、取消、快速反向拖动；
- 七个 routeType 的 iOS 真机 push/pop；
- 多共享元素层级、弧线、shuttle、目标缺失降级；
- Open Container 的 `fade/fadeThrough`、圆角、颜色、阴影和反向跟手；
- Reduce Motion、旋转、横向滚动冲突、后台恢复；
- 60/90/120 Hz 帧耗时、快照内存与泄漏。

未完成真机矩阵前，真机手势、帧率、内存和双端视觉一致性仍标记为 `[待确认]`。

## 13. 官方参考

- [Skyline Open Container](https://developers.weixin.qq.com/miniprogram/dev/framework/runtime/skyline/open-container.html)
- [Skyline Preset Route](https://developers.weixin.qq.com/miniprogram/dev/framework/runtime/skyline/preset-route.html)
- [Skyline Share Element](https://developers.weixin.qq.com/miniprogram/dev/framework/runtime/skyline/share-element.html)
- [Skyline Pop Gesture](https://developers.weixin.qq.com/miniprogram/dev/framework/runtime/skyline/pop-gesture.html)
- [Lynx 4.0 Native Modules](https://lynxjs.org/4.0/guide/use-native-modules.html)
- [Android Predictive Back](https://developer.android.com/guide/navigation/custom-back/support-animations-views)
- [UIKit Custom Transitions](https://developer.apple.com/documentation/uikit/view-controller-transitions)
