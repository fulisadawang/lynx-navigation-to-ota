# 三端页面路由协议

Android、iOS、HarmonyOS 都先把外部输入转换成 `LynxPageRequest`，容器不直接解析 URL。

## 支持入口

### 本地 Bundle

```text
assets://bundles/main.lynx.bundle
local://bundles/main.lynx.bundle
main.lynx.bundle
./main.lynx.bundle
```

纯文件名归一化到 `bundles/<name>`。Android 读取 assets，iOS 读取 App Bundle，HarmonyOS 读取 rawfile。

### Explorer

```text
file://lynx?local://main.lynx.bundle?fullscreen=true&orientation=portrait
```

该格式包含第二个 `?`，三端均使用专门解析分支。

### 统一壳协议

```text
lynxshell://open?bundle=main.lynx.bundle&title=订单详情
lynx://open?bundle=main.lynx.bundle
```

### Sparkling Playground 风格

```text
hybrid://lynxview_page?bundle=main.lynx.bundle&hide_nav_bar=1&screen_orientation=portrait
```

HarmonyOS 解析器会严格校验固定入口：`lynxshell://open`、`lynx://open`、`hybrid://lynxview_page`，不接受任意 Host 冒充页面路由。

## 参数别名

| 统一含义 | 支持别名 |
|---|---|
| Bundle | `url`、`bundle` |
| 初始数据 | `initData`、`initialData`、`initial_data` |
| 全局参数 | `globalProps`、`global_props` |
| 隐藏导航栏 | `hidden_nav`、`hide_nav_bar`、`hideNavBar`、`hideNavigationBar` |
| 显示导航栏 | `showNavigationBar`、`showToolbar` |
| 隐藏状态栏 | `hide_status_bar`、`hideStatusBar` |
| 方向 | `orientation`、`screen_orientation` |
| 背景色 | `backgroundColor`、`background_color` |
| 尺寸 | `width` / `width_px`、`height` / `height_px` |
| Debug HTTP | `allowHttpInDebug`、`allow_http_in_debug` |
| 稳定页面标识 | `routeKey`、`route_key` |
| 系统返回手势 | `backGestureEnabled`、`back_gesture_enabled` |

`initData` 与 `globalProps` 必须是 JSON Object；宽高必须大于 0；背景色必须为 `#RRGGBB` 或 `#RRGGBBAA`。

## Android / iOS 默认容器外观

Android 与 iOS 路由未显式提供外观参数时，默认使用：

```text
fullscreen=true
showToolbar/showNavigationBar=false
hideStatusBar=false
```

因此 Bundle 直接占满 Activity / UIViewController，`LynxView` 绘制到透明状态栏后方，
但时间、信号与电量保持可见；默认不会出现 Material Toolbar 或
`UINavigationBar`。确需非全屏宿主页时显式传 `fullscreen=false`；只有在非全屏下，
`showNavigationBar/showToolbar=true` 才会显示原生导航。只有显式传
`hide_status_bar=1` / `hideStatusBar=true` 才会真正隐藏状态栏。

## 远程地址

远程 Bundle 作为 `url` 参数时必须 URL 编码：

```text
lynxshell://open?url=https%3A%2F%2Fcdn.example.com%2Flynx%2Fmain.lynx.bundle
```

即使路由解析成功，Provider 仍会再次执行协议、Host、响应状态和体积校验。

## Android / iOS 原生栈控制

当前手写 `NativeModules.LynxShellModule` 支持：

```text
push / singleTop / clearTop / singleTask
close / back(delta) / popTo(routeKey)
closeAll / reLaunch / redirect
getNavigationState
closeWithResult / consumeNavigationResult
```

routeKey、sessionID、entryID、宿主锚点和完整调用示例见
[NAVIGATION_README.md](NAVIGATION_README.md)。

本阶段没有实现路由拦截；页面鉴权、登录跳转和异步放行仍应由业务 App Router 处理。
