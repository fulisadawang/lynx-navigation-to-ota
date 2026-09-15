# Lynx 4.1 三端 XElement 全量接入

“全量”以 Lynx `4.1.0` 的平台真实边界为准。Android 有聚合注册层，当前显式依赖为 12 项；iOS 为 11 个 subspec（含 Behavior 和 Video）；HarmonyOS 由核心 Registry 与官方 OHPM 包组成，不能把 Android Maven 坐标或 iOS subspec 机械翻译成不存在的 OHPM 包。

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
| Video（实验性） | `xelement-video` | `Video` | `@lynx/xelement_video` + Behavior |

## Android：11/11 Maven 产物

`android/lynx-shell/build.gradle.kts` 显式声明聚合产物、现有十类组件和 Video，统一为 `4.1.0`；PrimJS 使用官方组合 `4.1.1`。AnimaX 宿主接入由独立专项分支维护；官方聚合器可能携带其传递依赖。
同时补齐 LynxTExtra、ServalSVG、ServalMarkdown 与 RefreshLayout Kernel；这些依赖会
随 AAR 的 Maven POM 传递给业务 App。

统一注册入口：

```kotlin
builder.addBehaviors(XElementBehaviors().create())
```

Library 的 `consumer-rules.pro` 保留基础与 SVG 的 `BehaviorGenerator`，避免业务
开启 R8 后反射聚合被裁剪。

## iOS：11/11 subspec

`ios/LynxShellKit.podspec` 显式声明：

```ruby
spec.dependency 'XElement/Input', '4.1.0'
spec.dependency 'XElement/BlurView', '4.1.0'
spec.dependency 'XElement/Video', '4.1.0'
# Overlay / ScrollCoordinator / ViewPager / WebView / SVG /
# Refresh / Markdown / Behavior 同样逐项声明为 4.1.0。
```

`Behavior` 提供现有组件和 Video 的 AutoRegistry；Objective-C Runtime 导入公开元素头与 AutoRegistry 头作为编译期哨兵。静态 Framework 配置 `-ObjC`，防止自动注册类被链接器裁剪。

## HarmonyOS：10 类能力

`harmony/lynx_shell_kit` 的 4.1 Runtime 通过核心 Registry 和官方 OHPM 包提供：

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
video（实验性）
```

OHPM 依赖按官方 Explorer 真实形态声明：

```json5
"@lynx/lynx": "@param:dependencies.lynx_version",
"@lynx/xelement_markdown": "@param:dependencies.lynx_version",
"@lynx/xelement_svg": "@param:dependencies.lynx_version",
"@lynx/xelement_webview": "@param:dependencies.lynx_version",
"@lynx/xelement_video": "@param:dependencies.lynx_version"
```

注册方式：

```ts
XElementMarkdown.initialize();

const behaviors: BehaviorRegistryMap = new Map([
  ['svg', new Behavior(UISVG, undefined)],
  ['webview', new Behavior(UIWebView, undefined)],
  ['video', new Behavior(UIVideo, undefined)]
]);
```

BlurView、Input/TextArea、Overlay、Refresh、ScrollCoordinator、ViewPager 由核心 Native Registry 提供；Markdown 是进程级初始化；SVG/WebView/Video 是 `LynxView` 级 Behavior 注入。

## AnimaX 独立分支边界

AnimaX 的 Android 宿主适配已拆到独立分支；本升级分支不显式接入它；官方聚合器可能携带其传递依赖。当前
HarmonyOS OHPM registry 仍没有稳定的 `@lynx/xelement_animax` 产物，不能用其他平台的类名
或未知 HAR 替代官方包。

## 验收边界

静态脚本逐项检查 Android 11/11、iOS 11/11、HarmonyOS 10 类能力，以及各平台的真实注册方式。
本次 Module 化后 Android Library 与 iOS `LynxShellKit` 已完成真实依赖编译；仍未逐个
执行全部 XElement 的设备交互回归。
