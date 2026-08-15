# HarmonyOS 路由协议

容器只接受 `LynxPageRequest`。以下入口均先经过 `LynxRouteParser`。

## 本地

```text
assets://bundles/main.lynx.bundle
local://bundles/main.lynx.bundle
main.lynx.bundle
```

纯文件名会归一化为 `bundles/<name>`；绝对路径、`..`、反斜杠和空路径会被拒绝。

## Explorer

```text
file://lynx?local://main.lynx.bundle?fullscreen=true&orientation=portrait
```

该格式包含第二个 `?`，因此使用专门解析分支，而不是依赖标准 URL 查询器。

## 壳协议

```text
lynxshell://open?bundle=main.lynx.bundle&title=订单详情
lynx://open?url=local%3A%2F%2Fbundles%2Fmain.lynx.bundle
```

## Sparkling

```text
hybrid://lynxview_page?bundle=main.lynx.bundle&hide_nav_bar=1&screen_orientation=portrait
```

## 参数别名

- Bundle：`url`、`bundle`
- 初始数据：`initData`、`initialData`、`initial_data`
- 全局参数：`globalProps`、`global_props`
- 导航栏：`hideNavigationBar`、`hideNavBar`、`hide_nav_bar`、`hidden_nav`
- 状态栏：`hideStatusBar`、`hide_status_bar`
- 方向：`orientation`、`screenOrientation`、`screen_orientation`
- 路由动画：`animated`，布尔值，默认 `true`
- 背景：`backgroundColor`、`background_color`
- 尺寸：`width` / `widthPx` / `width_px`、`height` / `heightPx` / `height_px`
- 调试 HTTP：`allowHttpInDebug`、`allow_http_in_debug`、`allowHttp`、`allow_http`
- 键盘布局：`keyboardBehavior`、`keyboard_behavior`，值为 `system` / `resize` / `pan` / `nothing`

`animated=false` 仅关闭本次打开/替换目标页面的页面转场；不传或传 `true` 时保留
ArkUI Router 的系统默认动画。`clearTop` / `singleTask` 回退已有页面时仍由当前
`@ohos.router` 栈控制动画，若要让所有回退操作都严格按命令关闭动画，需要后续切换到
支持逐次动画参数的 NavPathStack 适配层。


## 固定入口校验

Host Schema 只接受以下三种组合：

```text
lynxshell://open
lynx://open
hybrid://lynxview_page
```

其他 Scheme/Host 即使携带 `bundle` 参数也会被拒绝，防止外部深链伪装成可信 Lynx 页面入口。

## OTA 逻辑地址

原生业务只传 appId、Bundle 名和页面参数，不传磁盘绝对路径：

```ts
await LynxRouter.openOta('10000001', 'home.lynx.bundle', { source: 'native' })
```

Lynx 页面继续调用 `LynxShellModule.open`，但在 `optionsJSON` 同时携带逻辑地址：

```ts
NativeModules.LynxShellModule.open(
  'home.lynx.bundle',
  JSON.stringify({ lynxAppId: '10000001', bundleName: 'home.lynx.bundle' }),
  callback
)
```

容器显示原生 Loading，等待 current/repair、size/SHA 和原子激活完成，再读取 prepared file
创建 LynxView。完整 HTTPS URL 仍是 Direct Remote Bundle，不进入 OTA Store。

当前 Demo 因服务端暂只接受 `android/ios`，通过 `LynxOtaConfig.serverPlatform = 'android'`
临时复用 Android release；这只是请求兼容层，不改变 HarmonyOS 容器、生命周期或页面平台。
