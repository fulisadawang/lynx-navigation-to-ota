# Lynx 4.0 三端 XElement 全量接入

“全量”以 Lynx `release/4.0` 的平台真实边界为准。Android/iOS 有聚合注册层，所以清单为 10 项；HarmonyOS 源码能力目录为 9 类，不能把 Android Maven 坐标或 iOS subspec 机械翻译成不存在的 OHPM 包。

## 三端映射

| 能力 | Android | iOS | HarmonyOS |
|---|---|---|---|
| 聚合行为 / 自动注册 | `xelement` | `Behavior` | 核心 Registry + 集中 Runtime |
| Input / TextArea | `xelement-input` | `Input` | `@lynx/lynx` 核心 Registry |
| BlurView | `xelement-blur-view` | `BlurView` | `@lynx/lynx` 核心 Registry |
| Overlay | `xelement-overlay` | `Overlay` | `@lynx/lynx` 核心 Registry |
| Refresh | `xelement-refresh` | `Refresh` | `@lynx/lynx` 核心 Registry |
| ScrollCoordinator | `xelement-scroll-coordinator` | `ScrollCoordinator` | `@lynx/lynx` 核心 Registry |
| ViewPager | `xelement-viewpager` | `ViewPager` | `@lynx/lynx` 核心 Registry |
| Markdown | `xelement-markdown` | `Markdown` | `@lynx/xelement_markdown` + `initialize()` |
| SVG | `xelement-svg` | `SVG` | `@lynx/xelement_svg` + Behavior |
| WebView | `xelement-webview` | `WebView` | `@lynx/xelement_webview` + Behavior |

## Android：10/10 Maven 产物

`android/lynx-shell/build.gradle.kts` 显式声明聚合产物和九类组件，统一为 `4.0.0`。
同时补齐 LynxTExtra、ServalSVG、ServalMarkdown 与 RefreshLayout Kernel；这些依赖会
随 AAR 的 Maven POM 传递给业务 App。

统一注册入口：

```kotlin
builder.addBehaviors(XElementBehaviors().create())
```

Library 的 `consumer-rules.pro` 保留基础与 SVG 的 `BehaviorGenerator`，避免业务
开启 R8 后反射聚合被裁剪。

## iOS：10/10 subspec

`ios/LynxShellKit.podspec` 显式声明：

```ruby
spec.dependency 'XElement/Input', '4.0.0'
spec.dependency 'XElement/BlurView', '4.0.0'
# Overlay / ScrollCoordinator / ViewPager / WebView / SVG /
# Refresh / Markdown / Behavior 同样逐项声明。
```

`Behavior` 提供九类 AutoRegistry；Objective-C Runtime 导入公开元素头与 AutoRegistry 头作为编译期哨兵。静态 Framework 配置 `-ObjC`，防止自动注册类被链接器裁剪。

## HarmonyOS：9/9 能力

`platform/harmony/lynx_xelement` 在 `release/4.0` 中包含：

```text
blur_view
input
markdown
overlay
refresh
scroll_coordinator
svg
viewpager
webview
```

OHPM 依赖按官方 Explorer 真实形态声明：

```json5
"@lynx/lynx": "@param:dependencies.lynx_version",
"@lynx/xelement_markdown": "@param:dependencies.lynx_version",
"@lynx/xelement_svg": "@param:dependencies.lynx_version",
"@lynx/xelement_webview": "@param:dependencies.lynx_version"
```

注册方式：

```ts
XElementMarkdown.initialize();

const behaviors: BehaviorRegistryMap = new Map([
  ['svg', new Behavior(UISVG, undefined)],
  ['webview', new Behavior(UIWebView, undefined)]
]);
```

BlurView、Input/TextArea、Overlay、Refresh、ScrollCoordinator、ViewPager 由核心 Native Registry 提供；Markdown 是进程级初始化；SVG/WebView 是 `LynxView` 级 Behavior 注入。

## 为什么没有 Video

`release/4.0` 三端官方边界中不包含后续 nightly 可能出现的 Video。升级时必须同步升级 Engine、PrimJS、Service、XElement、依赖清单和静态校验，不能单独倒灌一个高版本组件。

## 验收边界

静态脚本逐项检查 Android 10/10、iOS 10/10、HarmonyOS 9/9，以及各平台的真实注册方式。
本次 Module 化后 Android Library 与 iOS `LynxShellKit` 已完成真实依赖编译；仍未逐个
执行全部 XElement 的设备交互回归。
