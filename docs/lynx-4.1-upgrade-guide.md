# Lynx 4.1.0 全局升级与新增组件接入步骤

> 文档状态：已执行，结果以本分支实际构建和运行证据为准
>
> 适用分支：`codex/lynx-4.1-upgrade-components`
>
> 当前基线：Lynx 4.0.0，commit `5a1349246ac181d0f2f0945d9097ef9f17bae490`
>
> 目标：将 Android、iOS、HarmonyOS 和 Playground 统一升级到 Lynx 4.1 兼容组合，并接入
> 4.1 新增的 `Video` 能力。AnimaX 适配另见独立专项分支。

> 本次执行结果记录在 `.workflow/lynx-4-1-upgrade-components-2026-09-14/`：Android、iOS 和
> HarmonyOS 均完成 4.1 运行态验证；HarmonyOS 额外使用官方 4.1.0 源码构建的本地 Gfx HAR
> 补齐稳定 OHPM 包遗漏的 `liblynxgfx.so`。Video Demo 作为 direct asset 入口；AnimaX 不进入
> 本升级分支，Android 宿主适配另见独立专项分支，iOS/HarmonyOS 继续遵循各自兼容边界。

## 1. 升级目标与版本原则

Lynx 官方已经发布稳定版 `4.1.0`，版本列表将其列为最新稳定版本，`4.0.0` 为上一版本。

- [Lynx 版本列表](https://lynxjs.org/versions.html)
- [Lynx 4.1.0 Release](https://github.com/lynx-family/lynx/releases/tag/4.1.0)
- [官方现有应用集成文档](https://lynxjs.org/guide/start/integrate-with-existing-apps.html)

官方 4.1 的 Native 依赖不是所有包都使用同一个小版本，必须遵守下面的组合：

| 能力 | 目标版本 | 说明 |
| --- | --- | --- |
| Lynx Engine | `4.1.0` | Android、iOS、HarmonyOS 核心运行时 |
| Lynx JSSDK | `4.1.0` | Android 核心 JS SDK |
| Lynx Trace | `4.1.0` | Android Trace/Performance 运行库 |
| Lynx Service | `4.1.0` | Image、Log、Http 等服务 |
| XElement | `4.1.0` | 已接入组件统一升级 |
| PrimJS | `4.1.1` | Android、iOS、HarmonyOS 均按官方示例使用 |
| `@lynx-js/types` | `4.1.0` | Playground 类型契约 |
| `@lynx-js/react` | 兼容的 `0.x` | ReactLynx 包不是 4.1.0 编号 |
| `@lynx-js/react-rsbuild-plugin` | 兼容的 `0.x` | 需要与 Rspeedy/ReactLynx 一起锁定 |
| `@lynx-js/rspeedy` | 兼容的 `0.x` | 不能直接改成 `4.1.0` |
| `@lynx-js/qrcode-rsbuild-plugin` | `0.7.2` | 与 Rsbuild 2.x API 对齐 |
| `@rsbuild/core` | `2.2.3` | `@lynx-js/react-rsbuild-plugin@0.20.0` 的 peer 要求 |
| `@rspack/core` / `@rspack/binding` | `2.2.2` | Rsbuild 2.2.3 要求 Rspack 2.x |
| `@lynx-js/tasm` | `0.0.53` override | 模板插件默认旧版本只接受到 3.9，4.1 target 需要新版编码器 |

不要直接执行全仓库的 `4.0.0` → `4.1.0` 文本替换。PrimJS 应升级到 `4.1.1`，Playground 的
ReactLynx/Rspeedy 工具链应通过兼容性探测后再选具体 0.x 版本。

## 2. 4.1 新增组件清单

### 2.1 `<video>`：三端可用，但仍是实验性 XElement

官方将 `<video>` 标记为 `4.1 experimental XElement`，兼容 Android、iOS 和 HarmonyOS。

- [官方 `<video>` API](https://lynxjs.org/next/zh/api/elements/built-in/video.html)
- [官方 4.1 组件依赖示例](https://lynxjs.org/guide/start/integrate-with-existing-apps.html)

主要能力：

- 在线视频 `src`。
- `loop`、`volume`、`muted`、`speed`。
- `object-fit`、`mode`、`timeupdate-interval`。
- `bindfirstframe`、`bindplaying`、`bindpaused`、`bindstopped`。
- `bindtimeupdate`、`bindended`、`bindlooped`、`binderror`、`bindbuffering`。
- `play`、`pause`、`stop`、`seek` UIMethod。

当前基座状态和升级动作：

| 平台 | 当前状态 | 4.1 动作 |
| --- | --- | --- |
| Android | 已接入并在 API 35 AVD 完成首帧/播放/seek 验证 | 保留 `org.lynxsdk.lynx:xelement-video:4.1.0` 和聚合 Behavior 注册 |
| iOS | 已解析 `XElement/Video`，并在 iPhone 16 Pro Simulator 验证中文 locale、首帧、play、pause、seek | 业务媒体异常、后台播放、DRM、旋转和完整销毁矩阵待专项补充 |
| HarmonyOS | 已解析 `@lynx/xelement_video:4.1.0`、接入本地 Gfx HAR，并在 Mate X7 完成首帧/play/pause/seek | 业务媒体异常、后台播放、DRM、旋转和完整销毁矩阵待专项补充 |

Video 是实验性能力。只有依赖解析、编译、页面创建、首帧、播放、暂停、seek、错误和页面销毁
都通过后，才能把它记录为“基座已接入”。

### 2.2 AnimaX：独立专项，不进入本升级分支

本分支只接入 4.1 版本升级和 Video/XElement 能力。AnimaX 的 Android 依赖、资源 Fetcher、
图片拦截和 JS `fetch()` 适配单独放在 `codex/lynx-4.1-animax` 分支，避免把实验性动画
资源链路混入基础升级提交。iOS 仍需先解决 iOS 13 与 `SSZipArchive` 兼容边界，HarmonyOS
当前没有稳定的 `@lynx/xelement_animax` OHPM 包。

### 2.3 现有 XElement：全部升级版本，不作为新增组件

当前已接入的基础组件继续保留：

```text
Input
Overlay
ViewPager
ScrollCoordinator
SVG
Markdown
Refresh
BlurView
WebView
```

它们在 4.1 中主要执行版本升级：

```text
4.0.0 → 4.1.0
```

Mac Clay 专属的 `cover-view`、macOS 视频实现以及其他 Desktop/Clay 能力不纳入当前 Android、
iOS、HarmonyOS 移动基座升级。

## 3. 执行前保护工作区

执行任何依赖安装或代码修改前，先记录工作区：

```bash
git branch --show-current
git status -sb
git rev-parse HEAD
git log -2 --oneline --decorate
```

当前必须保留且不得暂存的用户文件：

```text
harmony/lynx_shell_kit/BuildProfile.ets
docs/superpowers/**
ios/LynxShell.xcodeproj/project.xcworkspace/
```

如果在当前 checkout 操作，暂存时只能加入升级相关路径。更安全的方式是从当前分支创建独立
升级 worktree，避免 OHPM/CocoaPods 或构建脚本影响用户已有 dirty 文件。

禁止：

- `git reset --hard`。
- `git checkout --` 覆盖用户文件。
- 删除或重建用户已有的 `docs/superpowers/**`。
- 修改 `BuildProfile.ets` 来绕过构建错误。
- 使用 npm 和 pnpm 共同管理 Playground 的同一安装目录。

升级前保存当前 4.0 基线信息：

- Android/iOS/Harmony 当前依赖版本。
- 当前所有 Bundle 的 SHA-256。
- 当前 `i18n-demo.lynx.bundle` 的 SHA-256。
- 当前 Native Tab、i18n、folded cover display 的截图或日志路径。
- 当前 PR #8 的状态和 head SHA。

## 4. 阶段一：验证 4.1 产物可解析

这一阶段只做探测，不改工程文件。

### 4.1 Android Maven

逐个确认以下产物存在：

```text
org.lynxsdk.lynx:lynx:4.1.0
org.lynxsdk.lynx:lynx-jssdk:4.1.0
org.lynxsdk.lynx:lynx-trace:4.1.0
org.lynxsdk.lynx:primjs:4.1.1
org.lynxsdk.lynx:lynx-service-image:4.1.0
org.lynxsdk.lynx:lynx-service-log:4.1.0
org.lynxsdk.lynx:lynx-service-http:4.1.0
org.lynxsdk.lynx:xelement:4.1.0
org.lynxsdk.lynx:xelement-video:4.1.0
```

如有组件依赖，继续核对 `xelement-input`、`xelement-overlay`、`xelement-viewpager`、
`xelement-scroll-coordinator`、`xelement-svg`、`xelement-markdown`、`xelement-refresh`、
`xelement-blur-view` 和 `xelement-webview` 的 4.1.0 产物。

### 4.2 iOS Specs

官方要求 Podfile 同时使用 CocoaPods CDN 和 Lynx 自有 Specs：

```ruby
source 'https://cdn.cocoapods.org/'
source 'https://github.com/lynx-family/Specs.git'
```

确认以下版本可解析：

```text
Lynx / LynxBase / LynxService / XElement：4.1.0
PrimJS：4.1.1
```

当前工程只使用 CocoaPods CDN，必须先确认 `lynx-family/Specs` 能在本机完成解析，再进入
Podfile/Podspec 修改。

### 4.3 HarmonyOS OHPM

确认以下包可解析：

```text
@lynx/lynx                 4.1.0
@lynx/lynx_base            4.1.0
@lynx/lynx_devtool         4.1.0
@lynx/lynx_devtool_service 4.1.0
@lynx/lynx_log_service     4.1.0
@lynx/lynx_http_service    4.1.0
@lynx/lynx_image_service   4.1.0
@lynx/xelement_markdown    4.1.0
@lynx/xelement_svg         4.1.0
@lynx/xelement_webview     4.1.0
@lynx/xelement_video       4.1.0
@lynx/primjs               4.1.1
```

`@lynx/xelement_animax` 没有稳定 OHPM 产物时保持缺席。

### 4.4 Playground npm

至少确认：

```text
@lynx-js/types@4.1.0
```

ReactLynx、React Rsbuild Plugin 和 Rspeedy 使用 0.x 版本，必须通过 peerDependencies、
`engineVersion` 和实际 Bundle 编译确认兼容关系。当前已验证的一组候选是 React `0.126.0`、
React Rsbuild Plugin `0.20.0`、Rspeedy `0.17.0`、Rsbuild `2.2.3`、Rspack `2.2.2`、二维码插件
`0.7.2`，并通过 pnpm override 使用 `@lynx-js/tasm@0.0.53`。不能把 `@lynx-js/react` 或
`@lynx-js/rspeedy` 直接写成 `4.1.0`。

## 5. 阶段二：升级 Android

### 5.1 修改依赖

修改 [android/lynx-shell/build.gradle.kts](../android/lynx-shell/build.gradle.kts)：

1. Lynx、JSSDK、Trace、Service、基础 XElement 全部切换到 `4.1.0`。
2. PrimJS 切换到 `4.1.1`。
3. 增加 `xelement-video:4.1.0`。
4. AnimaX 不在本分支依赖图，相关接入在独立专项分支处理。
5. 检查 `consumer-rules.pro` 是否需要保留 4.1 新增的 Video BehaviorGenerator。
6. 更新注释中的 `release/4.0` 组件范围，避免文档和依赖版本矛盾。

### 5.2 核对宿主接入

重点检查：

- [XElementRuntime.kt](../android/lynx-shell/src/main/java/com/example/lynxshell/runtime/XElementRuntime.kt)
  是否能通过官方聚合器注册 Video Behavior。
- `LynxContainerFactory` 创建每个 Builder 时是否仍然安装完整 BehaviorBundle。
- `LynxViewBuilder.setScreenSize`、`updateScreenMetrics`、`updateViewport` 签名是否兼容。
- `LynxViewClient` 的首屏、页面更新、Performance/Trace 回调是否兼容。
- Locale、layout、OTA、lease、generation 和转场代码不因升级被重建或绕过。

### 5.3 Android 构建和测试

先刷新依赖，再运行：

```bash
cd android
./gradlew --refresh-dependencies :app:assembleDebug :lynx-shell:testDebugUnitTest
./gradlew :app:testDebugUnitTest
```

通过后安装到现有 AVD，重新验证：

- Native Tab Home/Settings。
- `zh-CN` ↔ `en-US` 原位切换。
- 隐藏 Tab 同步。
- 重启后的 SharedPreferences 持久化。
- `i18n-demo.lynx.bundle` 的 route locale 和页面内切换。
- 现有 OTA、路由、返回和转场回归。
- Video Android AVD、iOS Simulator 和 HarmonyOS Mate X7 均已通过首帧/play/pause/seek；业务媒体异常和完整销毁矩阵仍待专项补充。
- AnimaX 不在本分支依赖图，动画业务验收放到独立专项分支。

## 6. 阶段三：升级 iOS

### 6.1 修改 CocoaPods 源和版本

修改 [ios/Podfile](../ios/Podfile)：

```ruby
source 'https://cdn.cocoapods.org/'
source 'https://github.com/lynx-family/Specs.git'
```

修改 [ios/LynxShellKit.podspec](../ios/LynxShellKit.podspec)：

- Lynx/LynxBase/LynxService：`4.1.0`。
- PrimJS：`4.1.1`。
- 现有 XElement subspec：`4.1.0`。
- Video：先从 4.1 `XElement` Specs 核对公开 subspec/头文件后增加。
- AnimaX：本分支不增加，待独立专项处理。

然后执行：

```bash
cd ios
pod install
```

检查 [ios/Podfile.lock](../ios/Podfile.lock) 中没有残留 4.0.0 的 Lynx/PrimJS/Service/XElement
依赖；业务侧第三方依赖不要随版本升级无关变动。

### 6.2 核对 iOS XElement 注册

当前 [LynxNativeRuntime.m](../ios/LynxShellKit/Native/LynxNativeRuntime.m) 已显式导入 4.1 的
公开 XElement 头文件和 Video AutoRegistry。升级时要：

1. 对照 4.1 `XElement` Specs 的 Video subspec。
2. 确认是否需要增加 Video 公开头文件。
3. 确认 `-ObjC`、AutoRegistry 和链接参数仍然有效。
4. 保持现有 XElement 注册聚合方式，不在业务页面里零散注册。

### 6.3 iOS 构建和测试

使用当前项目的 Xcode workspace/scheme 执行 Debug Simulator build/run 和 Scheme tests。验收：

- LynxShellKit 能完成 4.1 依赖链接。
- iPhone 16 Pro Simulator 能启动。
- Native Tab 语言切换、隐藏 Tab、UserDefaults 持久化通过。
- i18n Demo 的 route locale 和原位切换通过。
- 现有路由、转场和 OTA 测试没有新增失败。
- Video 依赖、公开头文件和 Simulator 编译接线通过；完整页面运行态仍需单独验证。
- AnimaX 不在本分支依赖图，不执行动画页面验收。

如果 Xcode 26 将 Lynx 4.1 的既有 warning 视为 error，优先按官方建议在 `post_install` 中
处理 warning 级别；不要直接关闭所有工程警告。

## 7. 阶段四：升级 HarmonyOS

### 7.1 更新 OHPM 版本

修改：

- [harmony/parameter.json](../harmony/parameter.json)
- [harmony/oh-package.json5](../harmony/oh-package.json5)
- [harmony/oh-package-lock.json5](../harmony/oh-package-lock.json5)
- [harmony/lynx_shell_kit/oh-package.json5](../harmony/lynx_shell_kit/oh-package.json5)
- [harmony/lynx_gfx/](../harmony/lynx_gfx/)

将核心、Service、现有 XElement 更新到 `4.1.0`，PrimJS 更新到 `4.1.1`，并增加：

```json5
"@lynx/xelement_video": "4.1.0"
```

不要增加没有 OHPM 稳定产物的 `@lynx/xelement_animax`。

官方 `@lynx/gfx@4.1.0` HAR 的 `libs/` 为空，而 `@lynx/lynx@4.1.0` 的 `liblynx.so` 依赖
`liblynxgfx.so`。工程使用官方 `4.1.0` tag 的 `gfx/platform/harmony` GN target 构建本地
`lynx_gfx` HAR，并在根 `oh-package.json5` 通过项目级 override 接入；不要用后续 nightly
二进制替换稳定版本。

### 7.2 更新 XElementRuntime

当前 [XElementRuntime.ets](../harmony/lynx_shell_kit/src/main/ets/common/XElementRuntime.ets)
显式导入 Markdown、SVG、WebView 和 Video。后续变更仍必须从实际 4.1 HAR 核对：

- `@lynx/xelement_video` 的导出符号。
- `UIVideo` 的注册入口。
- `XElementRuntime.initialize()` 是否需要显式初始化。
- `createBehaviors()` 是否需要增加 Video 的 Behavior。
- Video 的 ArkUI `Video` 生命周期和页面销毁行为。

这一步不能根据 Android/iOS 的类名猜 Harmony API。

继续保留：

- [ShellLocale.ets](../harmony/lynx_shell_kit/src/main/ets/common/ShellLocale.ets)
- [ShellLayoutState.ets](../harmony/lynx_shell_kit/src/main/ets/common/ShellLayoutState.ets)
- `lynxShellLocaleChanged`
- `lynxShellLayoutChanged`
- `updateScreenMetrics`
- `updateViewport`
- `onPerformanceEvent`
- `lynx_embedded_only=1` 本地验收入口

不得修改用户已有 [BuildProfile.ets](../harmony/lynx_shell_kit/BuildProfile.ets)。

### 7.3 Harmony 构建和设备验证

重新安装 OHPM 依赖后执行：

```bash
cd harmony
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHar --mode module -p module=lynx_gfx@default --no-daemon
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHar --mode module -p module=lynx_shell_kit@default --no-daemon
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleApp --no-daemon
```

安装到现有 Mate X7：

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
TARGET=127.0.0.1:5555
"$HDC" -t "$TARGET" install -r lynx_shell/build/default/outputs/default/lynx_shell-default-unsigned.hap
```

运行验收：

- 折叠态 cover display 的 `screen/viewport/safeArea`。
- Native Tabs 中英文切换。
- 冷启动语言持久化。
- `i18n-demo.lynx.bundle` 路由 locale 和原位切换。
- `onPerformanceEvent` 不出现 API/编译错误。
- Video 页面创建、首帧、播放控制、错误事件和销毁。
- 不加入 HarmonyOS AnimaX 测试，因为当前没有官方稳定 OHPM 包。
- 如果没有切换到展开姿态，不宣称展开态双栏业务布局通过。

## 8. 阶段五：升级 Playground 和生成 Bundle

### 8.1 选择前端工具链

先锁定最小变更组合：

1. `@lynx-js/types` 更新到 `4.1.0`。
2. 使用已验证的 React `0.126.0`、React Rsbuild Plugin `0.20.0`、Rspeedy `0.17.0` 作为首选
   组合，并保持精确版本锁定。
3. Rsbuild 升到 `2.2.3` 后，二维码插件使用 `0.7.2`，Rspack core/binding 使用 `2.2.2`。
4. 通过 pnpm override 使用 `@lynx-js/tasm@0.0.53`；模板插件 `0.16.x` 默认锁定的 `0.0.49`
   只能接受到 3.9，不能生成 4.1 target。
5. 不把 npm 包的最新版本自动当成 Lynx 4.1 版本。
6. 检查 `pluginReactLynx` 的 `engineVersion` 配置，确认生成 Bundle 的目标是 4.1。

### 8.2 构建和产物检查

只使用 pnpm：

```bash
cd playground
pnpm install
pnpm build
```

检查：

- 所有 Bundle 能生成。
- `main.lynx.bundle` 的 target/engine 配置为 4.1。
- `i18n-demo.lynx.bundle` 仍然是 direct asset 入口。
- 所有 Bundle 没有意外进入旧 OTA Manifest 身份。
- 产物体积与 4.0 基线做对比。

### 8.3 同步到三端

将生成的 Bundle 同步到：

```text
android/app/src/main/assets/bundles/
ios/LynxShellSample/Resources/Bundles/
harmony/lynx_shell/src/main/resources/rawfile/bundles/
```

同步 Harmony 的 direct rawfile Bundle；原有 `embedded-bundles.json` OTA fixture 保持原样，避免
将 Playground 4.1 资源混入旧 release。然后核对：

```text
Playground dist
= Android assets
= iOS Resources
= Harmony rawfile
```

`main.lynx.bundle` 和 `i18n-demo.lynx.bundle` 的 SHA 必须重新记录，不能沿用 4.0 构建时的值。

## 9. 阶段六：性能兼容性验证

Lynx 官方将性能能力分成线下 Trace 分析和线上 Performance API 监控两层：

- [分析性能](https://lynxjs.org/zh/guide/performance/analysis-performance)
- [监控性能总览](https://lynxjs.org/zh/guide/performance/monitor-performance)

4.1 升级阶段只做兼容性 smoke test，不把完整线上监控平台混入版本升级：

1. 确认 Android `lynx-trace:4.1.0` 可加载。
2. 确认 iOS 4.1 Pods 能链接 Trace/Performance 符号。
3. 确认 Harmony `onPerformanceEvent` 仍能收到 `PerformanceEntry`。
4. 使用官方 Performance API 示例 Bundle 验证 `init`、`metric`、`pipeline`、`resource` 事件。
5. 在测试页面标记 `fcp`、`actual_fmp` 和 `loadBundle` 观察路径。
6. 不在生产 Bundle 中打开 `performance.profile: true`。
7. 分别保存 DevTool Trace、设备日志和 Bundle 版本，避免用静态日志替代运行时性能证据。

本轮实际结果：Android API 35 AVD、iOS iPhone 16 Pro Simulator 和 HarmonyOS Mate X7 均加载
官方 `performance-api/dist/fcp-entry.lynx.bundle`，日志观察到
`lynx.performance.timing.onSetup` 和 `lynx.performance.onPerformanceEvent`；详细路径见工作流
`results/performance.md`。

性能验证要和我们自己的环境事件分开：

```text
lynxShellLocaleChanged / lynxShellLayoutChanged
```

是宿主语言/布局事件，不等于 Lynx `PerformanceEntry`。它们可以作为性能事件的上下文，不能
直接当成 FCP、ActualFMP 或 Pipeline 指标。

## 10. 完整验收矩阵

| 层级 | 必须通过的内容 |
| --- | --- |
| 版本 | Android/iOS/HarmonyOS Native 依赖为 4.1.0 + PrimJS 4.1.1；Playground target 为 4.1 |
| 组件 | 现有 XElement 全部升级；Video 三端运行通过；AnimaX 由独立专项分支维护 |
| Playground | `pnpm build` 成功，全部 Bundle 生成，i18n-demo 仍可直接打开 |
| Android | Gradle build、单测、模拟器安装、Native Tab、i18n、Video、OTA/路由回归 |
| iOS | Pod install、Simulator build/run、Scheme tests、Native Tab、i18n、Video、转场回归 |
| HarmonyOS | OHPM install、本地 Gfx/Kit HAR、App build、HDC 安装通过；Mate X7 已完成 Native Tab 中英文切换、4.1 direct Bundle、i18n 和 Video 运行态 |
| Bundle | 四处 direct asset SHA 一致；原有 OTA fixture manifest 保持并单独记录 |
| 布局 | screen metrics、viewport、safe area、layout revision 无回归 |
| 性能 | Android/iOS/HarmonyOS 均观察到官方 Performance timing/event 回调；未将宿主 Locale/Layout 事件冒充 PerformanceEntry |
| OTA | 有 Token 时验证真实 OTA；无 Token 时明确记录 embedded-only 边界 |
| 工作区 | `git diff --check` 通过，用户 dirty 文件未暂存 |

建议最终命令：

```bash
python3 scripts/static_check_android_ios.py --quiet
python3 harmony/scripts/check_harmony_shell.py --quiet
git diff --check
```

## 11. 停止条件

出现以下任一情况，停止继续扩大范围，先记录失败原因：

- 任一平台 4.1 稳定依赖无法解析。
- iOS 未使用 `lynx-family/Specs` 就无法解析 4.1 Pod。
- Harmony OHPM 安装成功但 Hvigor 编译失败。
- Playground 生成的 Bundle 仍然声明 4.0 target。
- 三端 Bundle SHA 不一致。
- 现有 Native Tab、Locale、OTA、lease、generation 或转场发生回归。
- Video 需要未确认的原生 API 或额外播放器能力；AnimaX 专项边界未确认。
- HarmonyOS 出现没有官方包却需要强行接入的组件。
- 构建依赖修改触碰了 `BuildProfile.ets` 或其他用户 dirty 文件。

## 12. 回滚和交付

### 12.1 回滚

如果某个平台无法完成 4.1 验收：

1. 保留失败日志、依赖解析结果和编译错误。
2. 回退本次 4.1 依赖/lockfile/Bundle commit。
3. 恢复 4.0 Bundle 的 SHA 和 Manifest 描述。
4. 不回滚用户原有 dirty 文件。
5. 继续保留已经验证通过的 4.0 PR #8。

### 12.2 交付

4.1 升级在独立分支 `codex/lynx-4.1-upgrade-components` 推进，PR #8 的 4.0 基线保持不变。推荐提交信息：

```text
build(lynx): Codex将三端基座与组件升级到4.1.0
```

提交正文需要说明：

- Android/iOS/HarmonyOS 实际依赖版本组合。
- iOS Specs 源变更。
- Harmony OHPM lock 变更。
- Playground 实际使用的 0.x 工具链版本。
- Video 是否纳入以及三端运行结果。
- AnimaX 是否进入独立专项分支以及 iOS 兼容方案。
- Bundle SHA 和 target/engine 结果。
- Native Tab、i18n、折叠态和性能 smoke test 结果。
- 真实 OTA Token 是否完成。
- 仍然延期的 HarmonyOS 共享元素、展开双栏、RTL 和多 Window/Scene。

PR 合并前必须再次确认：

```text
本地 HEAD = origin/head
PR head SHA = 本地 HEAD
用户 dirty 文件不在 commit 中
所有平台验证结果可追溯
```

## 13. 当前结论

本轮已经完成依赖升级、组件接线、Playground 4.1 Bundle 和跨端资源同步。`<video>` 标记为
experimental：Android、iOS、HarmonyOS 均有首帧/播放/暂停/seek 运行证据。HarmonyOS 通过
官方 4.1.0 源码构建的本地 Gfx HAR 补齐稳定 OHPM 包遗漏的动态库；普通 Tab 使用 direct
Bundle，显式 OTA fixture 仍保留 Manifest/current 读取路径。AnimaX 不进入本升级分支；其 Android
宿主适配、iOS 最低系统版本和压缩库兼容问题另行处理，HarmonyOS 继续不接入。

本分支没有自动 commit、push 或合并。用户已有 dirty 文件仍需在后续交付时按清单排除。
