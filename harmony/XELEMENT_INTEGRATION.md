# HarmonyOS XElement 全量接入说明

## release/4.0 的真实模块边界

HarmonyOS 与 Android/iOS 的发布方式不同，不能把 Android Maven 坐标或 iOS subspec 机械翻译成 9 个 OHPM 包。

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

## OHPM 依赖

`lynx_shell/oh-package.json5` 显式声明：

```json5
"@lynx/lynx": "@param:dependencies.lynx_version",
"@lynx/xelement_markdown": "@param:dependencies.lynx_version",
"@lynx/xelement_svg": "@param:dependencies.lynx_version",
"@lynx/xelement_webview": "@param:dependencies.lynx_version"
```

所有 `@lynx/*` 由根目录 `parameter.json` 固定为 `1.4.0`。

## 初始化与行为注册

```ts
XElementMarkdown.initialize();

const behaviors: BehaviorRegistryMap = new Map([
  ['svg', new Behavior(UISVG, undefined)],
  ['webview', new Behavior(UIWebView, undefined)]
]);
```

Markdown 是进程级初始化；SVG/WebView 是 `LynxView` 级 Behavior 注入。壳工程把两者分别放在 `XElementRuntime.initialize()` 和 `createBehaviors()` 中，防止页面遗漏。

## 为什么没有 Video

`release/4.0/platform/harmony/lynx_xelement` 的目录边界是上述 9 类，没有 Video。壳工程不会把更高版本或 nightly 组件倒灌到 Lynx 4.0 依赖链。

## 验收边界

已静态检查：

- 9 类名称均进入 `SUPPORTED_XELEMENTS`；
- 3 个独立 XElement OHPM 包均显式声明；
- Markdown 初始化存在且只通过集中入口调用；
- SVG/WebView Behavior 都注入 `LynxView`；
- 未出现伪造的 `@lynx/xelement-input` 等不存在 OHPM 坐标；
- 未混入 Video。

未执行 OHPM 解析和设备渲染，因此不能把静态检查描述为真机组件渲染通过。
