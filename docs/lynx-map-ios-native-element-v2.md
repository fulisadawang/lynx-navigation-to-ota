# iOS 高德地图 Lynx Native Element v2

v2 在 v1 的 `lynx-map` 原生 View、图层状态和覆盖物能力上，补齐了可安全跨 Lynx 边界的相机、交互、控件、Marker 选择与拖拽 API，并增加公交/地铁服务、Lynx 坐标覆盖层、海量点和可重复性能验收页。组件仍然只接收可序列化数据；`MAMapView`、`MAAnnotation`、`MAPolyline`、`MAMultiPointOverlay` 和高德 delegate 只存在于 iOS provider adapter 内。

## 暴露边界

`getCapabilities()` 的 `contractVersion` 为 `3`，并返回 `apiCatalog`：

- `element`：当前 `lynx-map` 可以直接调用的 UI 方法和事件。
- `service`：需要独立服务边界的 POI、地理编码、定位和路线规划能力；当前 iOS 已接入 `AMapLocation` 2.12.3，并由 `LynxMapLocationModule` 提供定位服务。
- `nativePage`：需要原生页面或系统级生命周期的导航、离线地图、截图和室内图能力。

这份目录解决“是否已经暴露”的判断问题。它不会把高德私有对象、任意 selector 或 Key 透传给 Lynx；未接通能力返回明确的 `planned`/`UNSUPPORTED` 语义，不返回假成功。

## Element API

### Props

```tsx
<LynxMap
  style={{ width: '100%', height: 320 }}
  center={{ latitude: 39.9042, longitude: 116.4074 }}
  zoom={12}
  bearing={18}
  pitch={12}
  anchor={{ x: 0.5, y: 0.5 }}
  mapType="standard"
  trafficEnabled
  zoomEnabled
  scrollEnabled
  rotateEnabled
  rotateCameraEnabled
  showsCompass
  showsScale
  showsLabels
  showsBuildings
  touchPOIEnabled
  layerVisible
  layerOpacity={1}
  layerZIndex={0}
  markers={[{
    id: 'store-1',
    coordinate: { latitude: 39.9042, longitude: 116.4074 },
    selected: false,
    draggable: true,
    icon: {
      uri: 'https://cdn.example.com/store.png',
      width: 44,
      height: 44,
      anchor: { x: 0.5, y: 1 },
    },
    view: {
      text: '店',
      backgroundColor: '#ff6a3d',
      foregroundColor: '#ffffff',
      cornerRadius: 22,
    },
  }]}
  massPoints={[{
    id: 'poi-1',
    coordinate: { latitude: 39.9042, longitude: 116.4074 },
    title: '海量点',
  }]}
/>
```

相机参数对应高德 `rotationDegree`、`cameraDegree` 和屏幕锚点：`bearing` 为 0 到 360（不含 360），`pitch` 为 0 到 60，`anchor.x/y` 为 0 到 1。手势和控件开关由 Lynx props 驱动，避免页面直接依赖 `MAMapView`。

`layer-visible`、`layer-opacity` 和 `layer-z-index` 作用于当前 Element 管理的 marker/polyline overlay 层；`map-type` 控制底图，`traffic-enabled` 控制实时路况。高德 overlay 仍受 `MAOverlayLevelAboveLabels` 同层约束，不能用一个全局 zIndex 假装跨底图、路况和文字层排序。

### UI Methods

- `moveCamera({ center?, zoom?, bearing?, pitch?, anchor?, animated? })`
- `getCamera()` / `getCameraState()`
- `fitBounds({ bounds, padding?, animated? })`
- `selectMarker(id, animated?)` / `deselectMarker(id, animated?)`
- `showMarkers(ids, padding?, animated?)`
- `getCapabilities()`
- `getPerformanceSnapshot()`
- `projectCoordinate({ latitude, longitude })`：返回 MapView 本地 `x/y/visible`，供同一相对定位容器里的 Lynx overlay 使用。

`getPerformanceSnapshot()` 只报告原生 adapter 已测得的 apply 次数、最近一次 apply 耗时、覆盖物数量、pending render 和 provider 状态。`fps`、`frameTimeMs` 在没有 `CADisplayLink`/Instruments 采样时明确返回 `null`，页面显示 `NOT_MEASURED`，避免把 JS 提交耗时冒充真实帧率。

### Events

- `ready` / `error`
- `maptap` / `longpress`
- `markertap`
- `markerselected` / `markerdeselected`
- `markerdrag`：`start`、`dragging`、`end`、`cancel`
- `masspointtap`：`MAMultiPointOverlay` 点点击，detail 只含 `id` 与坐标。
- `regionchange`：包含 `source`、`phase`、`reason` 时按原生事件提供

事件 detail 只包含 ID、坐标和字符串/数字状态，不携带高德对象引用。Marker 的 `selected`、`draggable` 由输入模型控制；交互回调回到 Lynx 后，页面可以通过受控 props 再次渲染状态。

Marker 的自定义显示也只跨边界传 JSON：`icon.uri` 目前要求 HTTPS，支持宽高、锚点和圆角；`view`
支持文字、背景色、前景色、边框和圆角。原生端使用复用的 `MAAnnotationView`，图片由
`SDWebImage` 做内存/磁盘缓存，并在 Marker 复用、页面销毁和 URL 变化时取消或丢弃旧请求。
这里的 `view` 是受控样式配置，不把任意 `UIView` 或 LynxView 引用传给原生。

## 布局与安全距离

`LynxMap` 的尺寸完全由 Lynx 布局决定：

- 固定尺寸：父容器给出确定的 `width`/`height`，例如 `320px`。
- 全屏：父容器使用确定高度的 `height: 100%` 或 `100vh`，地图填充可用区域。
- Lynx 覆盖层：`lynx-map` 和 Lynx `view` 放进同一个 `position: relative` 容器，覆盖层使用 `position: absolute`，绘制顺序放在地图之后。

所有地图页面都用 `SafeAreaView(edges={['top', 'bottom']})` 包住内容，顶部使用 `MapTopBar`。因此状态栏、灵动岛和底部 Home Indicator 不会覆盖标题、切换按钮或地图操作区；全屏模式只填充安全区内的可用高度，Lynx overlay 仍位于原生地图 View 之上。

## Demo 与性能验收

Playground 的“地图能力”分类提供独立的 API 验收入口，场景清单中的卡片也会跳转到同一页面：

1. **高德地图 Native Element**：地图手势、bearing/pitch、相机读取与移动、fitBounds、Marker 选择、覆盖物显隐和能力快照。
2. **地图固定 / 全屏布局**：切换 `320px` 固定高度和全屏，验证 Lynx overlay 与顶部安全距离。
3. **路线渲染实验室**：驾车、步行、骑行三种 fixture，起终点与途经点 Marker、Polyline 颜色/宽度/透明度、实时路况、fitBounds，并可请求 `AMapSearchKit` 算路结果。
4. **导航产品场景 Demo**：按产品界面拆分驾车总览、公交/地铁方案列表、骑行总览和步行总览；驾车/骑行/步行复用真实路线服务，公交/地铁可调用 `AMapTransitRouteSearchRequest` 返回序列化方案，网络失败时保留明确标记的 fixture。
5. **Marker 交互实验室**：12 个稳定 ID 的选中、点击、拖拽、显隐和事件顺序。
6. **图层与地图样式**：standard/satellite/night/navi 底图、实时路况、Marker/Polyline overlay、透明度、文字和建筑物独立切换。
7. **POI 与地理编码**：关键词 POI、逆地理编码、地理编码和结果 Marker，使用 `LynxMapSearchModule` 返回序列化 JSON。
8. **Lynx Marker Overlay**：用 `projectCoordinate` 将 Lynx 卡片叠到地理坐标，地图 regionchange 后重新投影，页面退出随 LynxView 释放。
9. **Marker 聚合**：普通 Marker 可在 Lynx 层开启确定性的网格聚合，聚合结果仍是受控 Marker，点击 detail.id 以 `cluster-` 开头；不把聚合对象传给原生 SDK。
10. **海量点性能实验**：500/1000/5000 点走独立 `MAMultiPointOverlay` lane；普通 Marker 仍保持 200 点上限，点击事件为 `masspointtap`。
11. **地图常见场景清单**：汇总以上页面，并列出截图、坐标转换、导航和生命周期场景的能力边界。
12. **Marker 性能与大场景**：固定 seed 生成 20/50/100/200 个合法普通 Marker，提供首次批量创建、No-op、全量替换、全量移动、局部 1% 更新和 10 次 burst；201/500/1000/5000 可以点击执行合约层拒绝检查，只作为超过普通 Marker 上限的边界，不会送入原生 adapter。
13. **高德定位 SDK**：`getCurrentLocation` 单次定位、`startLocation`/`stopLocation` 连续定位、权限状态和定位点回填地图；页面退出时自动停止连续定位。
14. **场景详情页**：暂未接通的能力进入详情页执行边界检查，返回链路和安全区布局保持一致，不返回假成功。

定位服务的原生方法通过 `LynxMapLocationModule` 暴露：`getCurrentLocation(optionsJSON)`、`startLocation(optionsJSON)`、`stopLocation()` 和 `getAuthorizationStatus()`。`optionsJSON` 只允许 `withReGeocode`、`desiredAccuracy`、`distanceFilter`、`locationTimeout`、`reGeocodeTimeout`，并在原生侧做范围校验。连续定位事件使用 `lynxMapLocation`，权限变化使用 `lynxMapLocationAuthorization`，错误使用 `lynxMapLocationError`；事件 detail 不携带设备标识或高德对象。

真实设备首次启动由宿主 `SceneDelegate` 展示高德隐私同意提示，用户同意后才配置地图和定位；模拟器验收使用 `--lynx-map-consent-granted` 启动参数。定位只申请 `When In Use`，后台定位、地理围栏和轨迹上报仍需要单独的宿主权限与产品协议。
性能记录分三层：

- Lynx/JS：页面显示提交窗口、N、K 和错误计数。
- Native：`getPerformanceSnapshot()` 提供 adapter apply 计数和耗时。
- 设备：绝对 FPS、卡顿、GPU、RSS 和 app-owned leaks 使用 `CADisplayLink`、Instruments、`queryMemoryUsage` 和 memgraph；模拟器只用于相对回归，真机再做绝对门槛。

普通 annotation 单个 Element 的 marker 上限为 200。小规模聚合由 ReactLynx typed 层做网格计算，输出受控 Marker；需要海量点时接入独立的 `MAMultiPointOverlay`/mass-points provider lane，不能把 500、1000 或 5000 个点塞入普通 marker 合约来“压测”。

## 生命周期与内存边界

销毁路径保持“取消异步任务 → 完成 pending callback → 暂停绘制 → 移除 delegate/listener → 移除 overlays → 清理 icon/renderer cache → detach → 释放 MapView”。generation 和 MapView identity 会丢弃迟到回调；UI method 有界队列和输入上限，避免重复 ID、大数组和异常浮点值把内存或渲染推入失控状态。

当前已在 Apple Silicon iPhone 16 Pro Simulator 上以 x86_64 translated build 验证地图、布局、顶部安全距离、能力快照、路线 Polyline、Marker 交互、图层切换和 POI 搜索；同一 Debug 包已使用 KMP 宿主签名配置构建并安装到 iPhone 11 Pro Max（iOS 16.4.1）。当前 Xcode 未提供该系统版本的 DeveloperDiskImage，真机自动启动和日志附加受此环境限制；长时间压力、绝对帧率和 Instruments/memgraph 仍需在设备上单独验收。
