# 三端验证说明

本轮针对 Android/iOS 的 Skyline 风格 `share-element`、`preset-route`、
`open-container` 和自定义返回手势完成源码、契约与 compile-only 验收。按用户要求，
没有安装或启动 App；HarmonyOS 未参与本轮功能改造，只做静态回归。

## 静态验收

```bash
python3 scripts/static_check.py
```

结果：

```text
Android / iOS : 99 PASS, 0 WARN, 0 FAIL
HarmonyOS     : 45 PASS, 0 WARN, 0 FAIL
三端合计      : 144 PASS, 0 WARN, 0 FAIL
```

本轮新增检查覆盖：

- 显式自定义转场不使用 Android `ActivityOptions` 或系统 Window 动画；
- iOS 显式转场不回落 UIKit 默认 animator，系统 edge pop 与壳手势互斥；
- 七种 `wx://` preset 使用对应原生 renderer，降级结果会真正切换 renderer；
- `clearTop / singleTask / back / popTo / closeAll / reLaunch` 只执行一段原生转场，
  中间 Activity/VC 静默提交；
- 多共享元素 1–8、key 唯一、push/pop shuttle、所有内置 rect tween 与逐元素
  `transitionOnGesture`；
- Android source underlay 擦除飞跃元素，iOS 使用独立 `shadowHost + clipHost`；
- Open Container 九项外观参数、`middleColor` 可空且仅参与 `fadeThrough`；
- `routeConfig`、bottom-sheet `routeOptions`、snapshot flags 和 `maintainState`；
- `completed / degraded / cancelled / failed` 终态事件以及 `animated=false`；
- TypeScript、Android、iOS NativeModules 契约与中文注释。

## 前端与 Bundle

```text
pnpm exec tsc --noEmit  PASS
pnpm build               PASS
```

Rspeedy 生成 16 个 `.lynx.bundle`，总输出约 2156.4 kB，并同步到 Android assets 与
iOS App Bundle Resources。

关键 Bundle SHA-256：

```text
go-bundles.lynx.bundle
0e4ccddeffec332b01904c5cb4c324596dcdbe4beda43ec45b705ba6f6347777

transition-gallery.lynx.bundle
0be339e0900ce98031c51f36973d97536a67c253a3f8fd9c958c942cb5b21838

transition-detail.lynx.bundle
a6f66f92f80d633245a0c478d08554e93d6d2ce505fbf4e4a82207ad2ed9cf2e
```

## Android 构建

由于源码包没有提交 Gradle Wrapper，本机使用缓存的 Gradle 8.11.1、Android Studio
JBR 与本机 Android SDK 执行：

```text
:app:compileDebugKotlin  BUILD SUCCESSFUL
:app:assembleDebug       BUILD SUCCESSFUL
```

产物：

```text
android/app/build/outputs/apk/debug/app-debug.apk
SHA-256: b2e6fc36feda9e976e57288dade36ec9bc42fb8c1f4fc379838bcee79e771fce
大小: 62,746,856 bytes
```

非阻塞警告：AGP 8.5.2 官方只声明测试到 compileSdk 34，而工程当前使用 compileSdk 35。
本轮没有擅自升级 AGP。

## iOS 构建

通过 `XcodeBuildMCP build_sim` 对以下 workspace 做 Simulator Debug 纯编译：

```text
workspace: ios/LynxShell.xcworkspace
scheme: LynxShell
configuration: Debug
simulator: iPhone 16 Pro
CODE_SIGNING_ALLOWED=NO
result: SUCCEEDED
errors: 0
```

构建日志：

```text
本机 XcodeBuildMCP workspace（路径因机器和会话不同而变化）
logs/build_sim_2026-07-29T12-46-30-092Z_pid43519_b6b91dfe.log
```

非阻塞警告来自第三方 Pod 的无符号对象文件，以及 PrimJS
`Create Symlinks to Header Folders` Script Phase 未声明 outputs。

## HarmonyOS 回归

HarmonyOS 静态检查为 `45 PASS, 0 WARN, 0 FAIL`。本轮没有修改 HarmonyOS，也没有执行
OHPM、DevEco、Hvigor、HAP 编译或签名。

## 未验证与边界

- 按用户要求，本轮没有安装、启动或操作 Android/iOS App；
- Android Predictive Back、API 24–33 edge back、iOS edge pan 的完成/取消视觉和帧率
  仍为 `[待确认]`；
- 七种 preset、多共享元素、Open Container、Reduce Motion、旋转、滚动冲突、后台恢复
  的真机矩阵仍为 `[待确认]`；
- WebView、视频、Surface/Metal 或受保护内容的快照质量不承诺；
- 真实业务 App 需要安装自己的 Android `SessionExitHandler/AppHomeHandler` 和 iOS
  Home Handler；
- 普通 NativeModules 无法执行 Skyline 任意 UI-thread
  `worklet:on-frame`、任意 `routeBuilder` 或 `withOpenContainer` 实例关联。本壳完整实现
  的是已声明的原生参数、白名单 tween、栈事务、降级与终态事件，不把视觉近似写成微信
  私有运行时 1:1 移植。

因此当前结论是：Android/iOS 源码、Bridge 契约、Bundle 和 Debug compile-only 构建已
验证；真机视觉/手势矩阵与 HarmonyOS 编译未覆盖，不能描述为三端生产验收完成。
