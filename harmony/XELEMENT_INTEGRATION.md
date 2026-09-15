# HarmonyOS Lynx 4.1 XElement 全量接入说明

## Lynx 4.1 的实际模块边界

HarmonyOS 与 Android/iOS 的发布方式不同，不能把 Android Maven 坐标或 iOS subspec 机械翻译成 OHPM 包。当前基座使用官方 Lynx 4.1.0 OHPM 包，PrimJS 单独使用官方 4.1.1。

| XElement | 接入方式 | 壳工程位置 |
|---|---|---|
| BlurView | `@lynx/lynx` 内置原生 Registry | `LynxRuntimeInitializer` 初始化 LynxEnv |
| Input / TextArea | `@lynx/lynx` 内置原生 Registry | 同上 |
| Overlay | `@lynx/lynx` 内置原生 Registry | 同上 |
| Refresh | `@lynx/lynx` 内置原生 Registry | 同上 |
| ScrollCoordinator | `@lynx/lynx` 内置原生 Registry | 同上 |
| ViewPager | `@lynx/lynx` 内置原生 Registry | 同上 |
| Markdown | `@lynx/xelement_markdown` | `XElementRuntime.initialize()` |
| SVG | `@lynx/xelement_svg` | `XElementRuntime.createBehaviors()` |
| WebView | `@lynx/xelement_webview` | `XElementRuntime.createBehaviors()` |
| Video（实验性） | `@lynx/xelement_video` | `XElementRuntime.createBehaviors()` |

## OHPM 依赖

`lynx_shell_kit/oh-package.json5` 显式声明独立 XElement：

```json5
"@lynx/lynx": "@param:dependencies.lynx_version",
"@lynx/xelement_markdown": "@param:dependencies.lynx_version",
"@lynx/xelement_svg": "@param:dependencies.lynx_version",
"@lynx/xelement_webview": "@param:dependencies.lynx_version",
"@lynx/xelement_video": "@param:dependencies.lynx_version"
```

核心、Service 和 XElement 由根目录 `parameter.json` 固定为 `4.1.0`；根包的 PrimJS 由同一参数文件固定为 `4.1.1`。4.1 的 `@lynx/lynx` 会引入 `@lynx/gfx@4.1.0`，由 OHPM lockfile 自动解析。

## 初始化与行为注册

```ts
XElementMarkdown.initialize();

const behaviors: BehaviorRegistryMap = new Map([
  ['svg', new Behavior(UISVG, undefined)],
  ['webview', new Behavior(UIWebView, undefined)],
  ['video', new Behavior(UIVideo, undefined)]
]);
```

Markdown 是进程级初始化；SVG、WebView 和 Video 是 `LynxView` 级 Behavior 注入。壳工程把它们分别放在 `XElementRuntime.initialize()` 和 `createBehaviors()` 中，防止页面遗漏。

## Video HAR 导出与运行边界

实际解析的 `@lynx/xelement_video@4.1.0` HAR 具有以下公开导出：

- `Index.ets` 导出 `UIVideo`、`VideoCommandScheduler`、`VideoEvents` 和 `VideoOptions`；
- `UIVideo` 继承 Lynx `UIBase`，可通过 `Behavior(UIVideo, undefined)` 注册到每个 `LynxView`；
- `UIVideo` 内部使用 ArkUI `Video` 与 `VideoController` 承载播放；
- 支持 Lynx `play`、`pause`、`stop`、`seek` UIMethod，并派发首帧、播放、暂停、进度、结束、循环、错误和缓冲事件。

Video 仍属于 4.1 experimental XElement。依赖解析和 HAR 编译通过只证明类型、导出和注册接缝成立；首帧、网络播放、控制方法、错误事件、页面返回和销毁仍需使用视频测试资源在目标设备上单独验收。

## 为什么没有 AnimaX

Android/iOS 4.1 有 AnimaX 接入路径，但 OHPM registry 没有稳定的 `@lynx/xelement_animax` 包。HarmonyOS 不声明或模拟该依赖，避免把不存在的官方能力写入宿主契约。

## 验收边界

已静态检查：

- 10 类名称均进入 `SUPPORTED_XELEMENTS`（Video 标记为 experimental）；
- 4 个独立 XElement OHPM 包均显式声明；
- Markdown 初始化存在且只通过集中入口调用；
- SVG/WebView/Video Behavior 都注入 `LynxView`；
- 未出现伪造的 `@lynx/xelement-input` 等不存在 OHPM 坐标；
- 未混入没有稳定 OHPM 包的 AnimaX。

已执行 OHPM 解析和 HAR/App 编译；Video 的真实首帧、播放控制、错误事件和销毁行为仍需设备媒体资源验收，不能仅以静态检查或编译通过代替。

当前 4.1.0 HarmonyOS 官方 `@lynx/gfx@4.1.0` HAR 没有携带 `liblynxgfx.so`，而
`@lynx/lynx@4.1.0` 的 `liblynx.so` 明确依赖它。工程已用 Lynx 官方 `4.1.0` tag 的
`gfx/platform/harmony` GN target 构建 arm64/x86_64 库，接入本地 `lynx_gfx` HAR，HAP
启动时可以正常加载 Core。该包的来源、符号覆盖和 ABI 边界记录在
[`harmony/lynx_gfx/README.md`](lynx_gfx/README.md)；不混用 nightly 二进制。
