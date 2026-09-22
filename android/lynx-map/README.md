# Android LynxMap Module

`lynx-map` 是 Android 侧独立的高德地图 Module。它由 `:lynx-shell` 依赖，并在每个
`LynxViewBuilder` 上安装 `LynxMapBehavior`；宿主页面只看到 provider-neutral 的
`<lynx-map>` Element 和 `LynxMapLocationModule` / `LynxMapSearchModule`。

## 宿主接入

- Module：`android/lynx-map`
- Lynx 注册点：`android/lynx-shell/.../LynxContainerFactory.kt`
- Android applicationId：`com.hugboga.custom`
- AMap 合包：`com.amap.api:3dmap-location-search:11.2.100_loc11.2.100_sea9.8.1`
- Key 来源：环境变量 `AMAP_API_KEY`，或 `KMP_CAPP_ANDROID_APP_CONFIG` 指向 KMP
  `capp-Android/appconfig.properties`；构建脚本只把值注入 BuildConfig 和 Manifest
  placeholder，不写入 Kotlin、Lynx Bundle、日志或文档。

Application 在创建 Lynx Router 前调用 `LynxMapRuntime.configure`，完成高德 Key、地图/定位
隐私状态和 SDK 初始化。Manifest 声明网络、Wi-Fi 和前台定位权限；系统定位权限仍由页面首次
调用定位 service 时检查。

## Element 和 service

`LynxMapUI` 当前覆盖：

- camera：`center`、`zoom`、`bearing`、`pitch`、`moveCamera`、`getCamera`、`getCameraState`、`fitBounds`；
- overlay：普通 Marker、Polyline、`mass-points`、图层显隐/透明度/zIndex、Marker 选中/拖拽/显示范围；
- map：标准/卫星/夜间/导航底图、实时路况、手势/指南针/比例尺/文字/建筑物/POI；
- overlay 边界：Marker 最多 200，Polyline 最多 50，海量点最多 5000；
- overlay 配合：`projectCoordinate`、`getCapabilities`、`getPerformanceSnapshot`，Lynx sibling
  overlay 仍由页面层叠在原生地图之上。

`LynxMapLocationModule` 使用 `AMapLocationClient` 提供单次定位、连续定位、停止、权限状态、
逆地理地址和结构化取消/失败结果。`LynxMapSearchModule` 使用 AMap Search/Route API 提供 POI、
地理编码、逆地理、驾车/步行/骑行和公交路线，以及取消/销毁后的迟到回调隔离。

UI Method 使用仓库内的 `LynxMapUI$$MethodInvoker` 生成类名约定，避免依赖未接入的
`lynxProcessor`；回调遵循 Lynx 4.1 的 `(code, data)` 形状。

## 模拟器和运行边界

高德 11.2.100 APK 中的地图 native library 以 arm64/armeabi-v7a 为主。当前验证使用 arm64
API 35 AVD，并以以下方式启动：

```bash
/Users/nieyutan/Library/Android/sdk/emulator/emulator \
  -avd LynxScreens_API35 -no-snapshot -no-boot-anim -gpu swiftshader_indirect
```

该 AVD 使用默认 gfxstream GPU 时，AMap `MapView`/`TextureMapView` 都会在 EGL context 创建阶段
崩溃；SwiftShader 后地图可以 ready、显示瓦片、Marker、Polyline 和 Lynx overlay。这个结论只
代表当前 AVD 的图形后端，真机硬件 GLES 仍需单独做运行态验证。若高德控制台没有为该包配置
安全码，日志可能出现 `INVALID_USER_SCODE`；本次地图仍可显示，但安全码绑定需在真实发布环境
按 KMP CAPP 配置补齐。

BottomSheet Demo 在 Android Lynx 4.1 使用背景线程触摸事件和 CSS transform transition，避免
当前 Android host 对 `MainThread.Element.animate` / main-thread 到 background 回调的不完整支持；
地图 camera 在吸附完成后通过 UI Method 更新，避免每个拖动帧触发高德 camera。
