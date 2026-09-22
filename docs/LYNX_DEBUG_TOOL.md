# Lynx Debug Tool（开发版）

当前仓库新增了一个完全独立的开发期调试工具能力，交互形态参考 Sparkling Debug Tool，但不依赖 Sparkling Runtime、autolink、codegen 或 OTA Server。

## 当前覆盖

当前版本通过 Shell 内部诊断 SPI 复用真实 Page/Native Tab 生命周期，记录以下有限现场：

- 全局入口：Android 在 App 内跨 Activity、iOS 在 App 内跨 UIWindowScene 页面提供可拖动的 `Lynx` window overlay；都不申请系统级悬浮窗权限，也不会悬浮到其他 App 上方；
- 页面筛选：先选择全部页面或具体 `viewId/routeKey`，再查看该页面的数据；
- 容器：`viewId`、Page/Tab、可见性、`routeKey`、标题；
- Bundle：来源、`lynxAppId`、`bundleName`、release 信息和已脱敏的 Bundle URL；
- GlobalProps：初始快照和后续 Shell 环境更新快照；
- 现有 `LynxMonitor` 事件：生命周期、加载、性能、JS Error、资源和诊断事件；
- 有界内存：单事件不超过 32 KiB，最多 128 条、总量不超过 512 KiB；
- Android 调试面板：固定高度的半屏 Bottom Sheet，包含 `Console`、`Network`、`Props`、`Methods` 四个 Tab；全局可拖动入口只能拖动悬浮球，面板本身不能下滑关闭，只能点击 `×`。
- iOS 调试面板：全局悬浮入口使用独立 passthrough window，只拦截自身触摸；拖动后吸附左右边缘并持久化位置。点击后使用系统 page sheet 的唯一 `.large` detent，保留状态栏和顶部圆角，视觉高度约为整屏 90%；包含同样的四个 Tab、页面选择、卡片化展示和逐条复制；`isModalInPresentation` 阻止交互式关闭，只保留 `×`。
- Network：Android 包装官方 `ILynxHttpService`；iOS DebugKit 精确 hook Lynx 4.1 `LynxHttpService` 的普通和 streaming fetch 入口。记录真实 method、脱敏 URL/headers/body、状态码和耗时，并生成可复制 cURL；streaming 耗时明确表示 TTFB。
- 页面数据进入 UI 前先结构化、脱敏和限长，不把原始 JSON 直接铺满界面；面板不写文件、不上传。

GlobalProps、URL、Bundle metadata、Native Method 参数和监控事件进入 Debug Store 前会做字段脱敏和长度限制。页面销毁时会移除页面快照和对应 Console 注册；调试 Store 不持有 Activity、UIViewController 或 OTA lease。

## Android

Android 新增 `android/lynx-debug-tool` Library。它只通过 Sample 的 `debugImplementation` 引入，且不提供非 Debug variant，Release 不包含 Debug Activity、`LynxDebugModule`、Debug Store 或调试入口。

Sample 的 `src/debug` Manifest 选择 `LynxShellDebugApplication`：先由父类完成 Core Runtime 及官方 DevTool 的 Debug 接线，再安装端内面板、Console、HTTP 观察层和浮球，不重复注册官方 DevTool Service，也不在启动时强制改写用户开关。采集从面板 `install()` 开始，初始化之前的事件不补录；正常页面在 Application 初始化之后创建。生产 Application 不含调试安装或反射入口。安装后，当前前台 Activity 的底部会出现一个可拖动的 `Lynx` 标签；点击后打开半屏 Inspector。页面侧也可以调用：

```ts
NativeModules.LynxDebugModule.getSnapshot((snapshotJSON: string) => {
  // snapshotJSON 是已脱敏、有界的 JSON 字符串
})

NativeModules.LynxDebugModule.clear((result) => {})
NativeModules.LynxDebugModule.open((result) => {})
```

业务 App 接入时应在 Debug Application 完成 `LynxRouter.install` 后、创建首个页面前显式调用：

```kotlin
LynxDebugTool.install(this)
```

`activateRuntimeFlags()` 只保留给宿主显式重新开启调试，不属于自动启动步骤；它会主动覆盖对应开关。

不应把 `implementation(project(":lynx-debug-tool"))` 或 `releaseImplementation` 加入业务 Release 构建。

Shell 的真实 `LynxDebugBridge` 位于 `lynx-shell/src/debug/java`。共享源码中只允许用成对的
`// LYNX_DEBUG_TOOL_BEGIN` / `// LYNX_DEBUG_TOOL_END` 标记调试 import 和完整语句块。
`GenerateProductionSources` 在每个非 Debug variant 编译前同步生成不含这些块的源码，检查标记配对和残留引用；
生产 Kotlin/Java 编译及 AGP 的 `sourceReleaseJar` 使用这份生产输入。Debug 仍编译原始共享源码和真实 Bridge。
此隔离不依赖 R8，不提供 Release 调试空实现。发布的 Release AAR 已移除 SPI，调试工具必须配套使用 Debug variant 的 Shell。

## iOS

新增 `ios/LynxShellDebugKit`，Podfile 只在 Debug configuration 引入：

```ruby
pod 'LynxShellDebugKit', :path => '.', :configurations => ['Debug']
```

在 `LynxShell.bootstrap()` 之后安装，面板不改写官方 DevTool 开关；官方 Inspector 的依赖与生产解析模式见 [Module 接入说明](../MODULE_INTEGRATION.md#非生产-devtool-默认能力)：

```swift
#if DEBUG
LynxDebugTool.install()
#endif
```

在业务 Scene 建立主 UIWindow 后绑定当前 `UIWindowScene`，即可让悬浮入口跨原生页和 Lynx 页常驻：

```swift
#if DEBUG
LynxDebugTool.attach(to: windowScene)
#endif
```

悬浮窗口不会成为 key window，窗口空白区域会把触摸穿透给业务页面；打开调试面板时入口隐藏，点击 `×` 关闭后恢复。

显示原生面板：

```swift
#if DEBUG
LynxDebugTool.present(from: presenterViewController)
#endif
```

Sample 还提供仅 Debug 的 `--show-lynx-debug-tool` 启动参数，便于模拟器验收；业务 App
仍可从自己的调试入口调用 `present(from:)`。

Release 不链接该 Pod，也不应把 Debug Bundle 或调试按钮放入 Release Resources。

`LynxShellKit/Diagnostics/LynxDebugBridge.swift` 的全部声明，以及 Page、Native Tab、Native Method、
Monitor 中的诊断计算和调用均受 `#if DEBUG` 保护。DebugKit 的三个 Swift 文件及 HTTP `.h/.m` 同样完整保护。
Sample 的 Podfile 在生产配置中进一步排除 `LynxDebugBridge.swift`，并排除 DebugKit 的 Swift 和 HTTP hook `.m` 编译输入。
各 Pod 使用自身构建条件，不能假定 App 的宏自动传播。正常 Router、GlobalProps 更新、HTTP Service 和生产 Monitor 不受影响。

iOS Network 只覆盖经过 Lynx 4.1 `LynxHttpService` 两个入口的请求（通常是页面 fetch），不抓宿主其他 `URLSession`、图片、模板或 OTA 下载。Lynx 4.1
的 `setHttpInterceptor` 实现固定返回 `NO`，因此 DebugKit 在 Debug Pod 内对该 service 的两个真实调用入口做一次性 hook；不修改生产 Shell 的网络执行和回调结果。只有进程内确实仅存一个 Lynx 容器时才关联其 `viewId`，多页面请求保留为 `unassigned`，只在“全部页面”展示，避免把后台请求误归到当前可见页。

## Native Method 接入边界

当前 Android 和 iOS 都已接入 Shell 自己的 `LynxShellModule` 导航方法调用。其他由业务注册的 NativeModule 不会被日志文本自动猜测；在真实方法入口和唯一终态处接入同一个 tracker：

```kotlin
val token = LynxDebugBridge.beginMethod("MyModule.load", paramsJSON, mContext)
// 执行业务原生方法
LynxDebugBridge.finishMethod(token, code = 0, success = true, result = resultJSON)
```

iOS 侧应在同一页面的 NativeModule 入口调用 `LynxDebugBridge.recordMethod(...)`，传入已经
脱敏的 `viewId`、参数、返回码、耗时和结果。

传入 `mContext` 后，Debug Bridge 会通过当前 `LynxContext.getLynxView()` 关联页面；页面重建或销毁后，旧调用不能归到新 generation。

## 当前未宣称已接通的能力

- 依赖 Lynx 4.1 DevTool owner 的 iOS Console 已接入；没有 owner 的页面会显示诚实空态；
- 尚未显式接入的第三方/业务 NativeModule 的自动参数、返回值和真实耗时追踪；
- Bridge 自动重放；
- Lynx DevTool/CDP、元素检查、Trace 或 Recorder；
- HarmonyOS Debug HAR；
- 真机性能、无泄漏、无 ANR 或签名发布包验收。

当前 Debug Store 复用的是已经存在的 Lynx 监控事件；“事件已记录到本地内存”不等于已经上传到远端平台。后续如接入官方 DevTool，必须使用与当前 Lynx 4.1.0 完全匹配的 Debug 依赖，不得使用本机缓存中的其他版本。

Sparkling 官方 Debug Inspector 当前公开的面板是 Log、Sparkling Method 和 GlobalProps，并没有 Network Tab；本项目的 Network 是基于当前 Lynx 4.1 HTTP Service 额外实现的能力，不能把它描述成 Sparkling 原生能力。

## 生产隔离验收

以构建 variant/configuration 判断开发或生产，不依据 OTA 服务地址或 `environment` 字段。
发布范围仅排除本项目新增的 Debug Tool；上游 Lynx SDK 自带的调试接口声明和此前的 OTA/监控诊断不属于这个独立模块。

Android 构建真实 Release AAR、发布源码包、APK、AAB，并保留 Debug 对照：

```bash
cd android
gradle :lynx-shell:assembleRelease :lynx-shell:sourceReleaseJar \
  :app:assembleRelease :app:bundleRelease :app:assembleDebug
cd ..
python3 scripts/check_debug_tool_release.py --android \
  android/lynx-shell/build/outputs/aar/lynx-shell-release.aar \
  android/lynx-shell/build/intermediates/source_jar/release/release-sources.jar \
  android/app/build/outputs/apk/release/app-release-unsigned.apk \
  android/app/build/outputs/bundle/release/app-release.aab \
  --debug-apk android/app/build/outputs/apk/debug/app-debug.apk
```

必须检查 AGP 的 `sourceReleaseJar` 发布产物；其他同名相近的空 Jar 不能作为通过证据。
检查器递归读取 AAR 内的 `classes.jar`、APK/AAB 的 dex、源码包内容和资源，发现自有 Debug 包名、
Bridge、Debug Application 或未移除标记即失败；空源码包也会失败。

iOS 在实际构建目录上运行检查器：

```bash
python3 scripts/check_debug_tool_release.py \
  --ios-app "$BUILD_PRODUCTS_DIR/LynxShell.app" \
  --ios-inputs "$SHELL_SWIFT_FILE_LIST"
```

其中两个变量分别指生产构建的 Products 目录和 Shell Release 的 `LynxShellKit.SwiftFileList`。
检查器覆盖 App 主二进制、嵌入的 dylib/framework（包含 Xcode Debug 对照用的 `.debug.dylib`），
检查自有调试符号、hook 和资源；`--debug-ios-app` 可追加一个 Debug App 作为正向对照。

2026-09-22 整合 `main@6827788` 后的实际验收结果：

| 产物/检查 | 结果 |
| --- | --- |
| Android Release AAR | 573 个 class，本次 Debug Tool 标记 0 |
| Android Release APK / AAB | 各 3 个 DEX，本次 Debug Tool 标记 0 |
| AGP Release sourcesJar | 64 个源码文件，无诊断实现、调用、调试专用参数或过滤标记 |
| Android Debug APK 对照 | DEX 类定义表确认 Tool、Bridge、Store、Debug Application 四类均存在 |
| iOS Release iphoneos arm64 App | 未签名构建成功，自有调试符号、hook、资源均未检出 |
| iOS Release Shell 编译输入 | 46 个文件，不包含 `LynxDebugBridge.swift` |
| iOS Debug Simulator 对照 | 构建成功，主体 `.debug.dylib` 中保留调试实现 |
| 既有静态验收 | 113 PASS / 0 WARN / 0 FAIL |

Android Release `LynxContainerFactory.create/create$default` 已通过字节码检查恢复原业务签名，
不携带 `containerKind`；私有 `postResult` 不携带诊断方法名参数。该轮没有执行签名发布或真机运行验收。
主分支的 iOS 14 部署版本配置保持不变；本机 Xcode 27 构建仅通过命令行临时指定 iOS 15，
该构建结果不替代 iOS 14 真机兼容性验证。地图 Framework 的模拟器验证使用 x86_64 架构。

构建 API 与 DEX 类定义检查分别参照 [AGP Sources API](https://developer.android.com/build/extend-agp#contribute-generated-sources-to-the-build)
和 [Android DEX 格式](https://source.android.com/docs/core/runtime/dex-format#class-def-item)。
