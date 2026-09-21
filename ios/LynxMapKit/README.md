# LynxMapKit

`LynxMapKit` 是独立的 iOS 地图能力 Module，负责：

- `lynx-map` Native Element 与 provider-neutral 合约；
- 高德 `MAMapView`、Marker、Polyline、图层、相机和生命周期 adapter；
- Marker 自定义 View：HTTPS 图片、尺寸、锚点、圆角、文字、背景色、边框和选中态；
- `LynxMapSearchModule` 的 POI、地理编码和驾车/步行/骑行算路；
- `LynxMapSearchModule` 的公交/地铁 `searchTransit` 方案服务；
- `LynxMapLocationModule` 的单次定位、连续定位和授权状态；
- `MAMultiPointOverlay` 海量点 provider lane，以及 `projectCoordinate` 驱动的 Lynx sibling overlay；
- AMap Key、隐私同意状态和 LynxConfig 注册入口。

`LynxShellKit` 只依赖本模块的 `LynxMapModuleRuntime`，不再编译地图实现源码，也不直接声明高德 SDK 依赖。
Marker 的 `icon` / `view` 只接受 JSON 配置；图片下载、缓存、取消和复用都由本模块管理。

Shell 接入点：

```objc
[LynxMapModuleRuntime bootstrapWithAPIKey:key privacyAgreed:agreed];
[LynxMapModuleRuntime registerModulesIntoConfig:config];
[LynxMapModuleRuntime registerUIElementsIntoConfig:config];
```

地图 Key、隐私同意状态和宿主权限仍由业务 App 控制；地图页面不能通过 props 注入 Key。
