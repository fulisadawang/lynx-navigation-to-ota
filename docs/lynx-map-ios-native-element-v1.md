# iOS 高德地图 Lynx Native Element v1

这次接入把高德 `MAMapView` 封装成 `lynx-map` Custom Native Element。Lynx 页面只接触可序列化的坐标、覆盖物、图层状态和事件；`MAMapView`、`MAAnnotation`、`MAPolyline` 以及高德 listener 都留在 iOS provider adapter 内。

## 宿主配置

`LynxShell` 的 iOS target 已按 KMP `capp-iOS` 的目标语义对齐：Bundle ID 为 `com.huangbaoche.client.store`，最低系统版本为 iOS 14，签名使用宿主的 Automatic signing / Apple Development 配置。没有复制 KMP 的 entitlements、证书、Provisioning Profile 或真实高德 Key。

高德 Key 可以通过宿主构建配置注入：

```text
LYNX_AMAP_API_KEY=<通过本机未跟踪 xcconfig 或 CI secret 注入>
```

`LynxMapAPIKey` 只作为宿主 Key 的构建注入入口。隐私同意状态不能用静态 `YES` 预置；宿主在用户完成高德隐私授权后、创建地图所在 LynxView 前调用 `LynxNativeRuntime.configureAMap(apiKey:privacyAgreed:)`，或调用 `updateAMapPrivacyAgreed(true)` 保留已配置 Key。Key 不进入 Lynx Bundle、Element props、事件或日志；缺少配置或未同意时组件发送明确的 `error`，不会发送假 `ready`。

## Lynx API

### Props

```tsx
<LynxMap
  style={{ width: '100%', height: 320 }}
  center={{ latitude: 39.9042, longitude: 116.4074 }}
  zoom={12}
  mapType="standard"
  trafficEnabled
  layerVisible
  layerOpacity={1}
  layerZIndex={0}
  markers={[{ id: 'beijing', coordinate: { latitude: 39.9042, longitude: 116.4074 } }]}
  polylines={[{ id: 'route', points: [start, end], color: '#0A7CF9', width: 6 }]}
/>
```

v1 的可编辑图层包括底图（`map-type`）、实时路况（`traffic-enabled`）和当前 Element 的 marker/polyline 覆盖物层（`layer-visible`、`layer-opacity`、`layer-z-index`）。高德 overlay 的排序受 `MAOverlayLevelAboveLabels` 同层约束，能力快照会明确返回这一边界，不承诺跨高德层级的全局排序。瓦片、热力图、图片、行政区和自定义样式层保留为后续带类型 ID 的扩展，不用任意参数透传掩盖未接通能力。

组件尺寸完全由 Lynx 布局决定：固定宽高直接给具体数值；全屏使用父容器的 `width: 100%`、`height: 100%`（父容器本身必须有确定高度）。需要 Lynx 内容盖在地图上时，把 Lynx `view` 与 `lynx-map` 放在同一个 `position: relative` 容器中，并让覆盖层使用 `position: absolute`。地图 Native Element 会响应 `frameDidChange`、`layoutSubviews` 和窗口 attach/detach。

### UI Methods

- `moveCamera({ center?, zoom?, animated? })`
- `getCamera()`
- `fitBounds({ bounds: { southwest, northeast }, padding?, animated? })`
- `getCapabilities()`

`getCapabilities()` 返回 provider、可用状态、支持的能力和有界资源上限。它不会返回 Key、Bundle ID 或高德活体对象。当前 AMap adapter 暴露 camera、fitBounds、map tap、marker tap、region change、marker/polyline、底图/traffic、覆盖物可见性/透明度/同层排序和 pause/resume；`features.amap.layers` 会列出 `base`、`traffic`、`marker`、`polyline`。

### Events

- `ready`: provider 已完成地图加载并且容器有有效尺寸。
- `error`: `{ code, message }`，包含 SDK、Key、隐私、参数和取消等明确错误。
- `maptap`: `{ coordinate }`
- `markertap`: `{ id, coordinate }`
- `regionchange`: `{ center?, zoom?, source?, phase?, reason? }`

## 生命周期与内存边界

每个 `lynx-map` 都拥有独立 adapter 和 `MAMapView`。销毁时按“取消异步任务 → 完成 pending callback → 暂停绘制 → 移除 delegate/listener → 移除 overlays → 清理 icon/renderer cache → 从容器 detach → 释放 MapView”的顺序执行，并用 generation 与 MapView identity 丢弃迟到回调。

单个 Element 的输入上限固定为：marker 200 个、polyline 50 条、单条 polyline 512 个点、所有 polyline 合计 5000 个点、pending UI Method 16 个、待执行 render task 1 个；ID 最长 128 字符、marker 文本最长 256 字符、折线颜色最长 16 字符、zoom 0 到 24、线宽不超过 128、fitBounds padding 不超过 4096、zIndex 绝对值不超过 100000。原生和 TypeScript 两侧都校验 ID 唯一、坐标有限且在合法经纬度范围内，避免大数组、重复 ID 和异常浮点值导致内存或渲染失控。

## 当前边界

- v1 面向 Lynx Native Element，不把高德全部私有 API 直接透传给 JS；provider-neutral 合约通过 capability snapshot 逐项声明能力。新增高德能力应先扩展合约、adapter 和 TS 类型，再增加设备验收。
- 能力 backlog：POI/地理编码/路线规划使用独立 Map Service；定位、离线地图、截图、室内图、tile/heatmap/image overlay、自定义样式和海量点渲染分别进入后续 provider 扩展，状态统一记录为 `planned`，不在 v1 返回假成功。
- 地图 SDK 由 `LynxShellKit.podspec` 声明为 `AMap3DMap 11.2.100`，Key 与 Bundle ID 从 KMP `capp-iOS` 的宿主配置读取。当前 Apple Silicon 模拟器用 x86_64 translated build 验证通过；官方二进制的 arm64 slice 仍标记为 iOS device，原生 arm64 Simulator link 会被 Xcode 拒绝。
- 当前已执行 `pod install`、`pod update`、Playground build、`arm64` Simulator link 失败边界验证，以及 Apple Silicon 模拟器上的 x86_64 translated build、安装和运行验收。`AMapFoundation` 的 CocoaPods xcconfig 会排除 `arm64` Simulator，原生 `arm64` link 会被 Xcode 报为 device binary；x86_64 translated build 可以在当前模拟器显示地图。真机 arm64 仍需在具备签名和网络条件的设备上验收。
