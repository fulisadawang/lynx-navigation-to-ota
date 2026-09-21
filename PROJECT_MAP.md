# PROJECT_MAP

## 项目定位

`lynx-navigation-to-ota` 是独立的 Lynx 4.1 三端原生 Router + OTA 源码工程，并包含尚未接入
默认 Sample 的三端 `LynxCapacitorModule` 原生能力源码。
三端 Shell 业务方分别引入一个平台模块：Android AAR、iOS CocoaPods Module、HarmonyOS HAR。
本仓库不包含旧的 `LynxScreens-Android` 工程，也不依赖 Sparkling 原生 SDK。

## 顶层结构

```text
android/                  lynx-shell AAR、lynx-capacitor 源码 + 可运行 Sample
ios/                      LynxShellKit/LynxMapKit Pods、LynxCapacitorKit 源码 + 可运行 Sample
harmony/                  lynx_shell_kit、lynx_capacitor_kit 源码 + Entry Demo
playground/               ReactLynx 多 Bundle 示例与 typed NativeModules wrapper
examples/                 页面侧 NativeModules 类型声明
scripts/                  三端 Bundle 同步与静态验收
MODULE_INTEGRATION.md     三端 Module 安装、宿主接线与调用方式
ARCHITECTURE.md           三端页面模型与 Runtime 分层
ROUTER_CONTRACT_V1.md     Android/iOS/HarmonyOS 页面语义契约
BRIDGE_CONTRACT.md        NativeModules 调用协议
ROUTING.md                Bundle、Scheme 与 params 路由规则
NAVIGATION_README.md      高级原生栈与返回/结果协议
TRANSITIONS_README.md     原生容器转场协议
SECURITY.md               Bundle、HTTPS、缓存和运行时安全边界
XELEMENT_INTEGRATION.md   Lynx 4.1 XElement 全量依赖清单
VALIDATION.md              分层验证命令与结果边界
```

## 平台模块边界

### Android

```text
android/lynx-shell/
├── src/main/java/com/example/lynxshell/
│   ├── LynxRouter.kt                  Router + OTA 公开门面
│   ├── container/                      Activity-first Lynx 容器
│   ├── routing/                        Native Page Stack 与转场
│   ├── bridge/                         NativeModules、Storage、页面消息
│   └── runtime/                        Lynx 4.1/XElement/Provider
└── src/main/kotlin/com/ota/android/sdk/
    └── 完整 Manifest、CAS 下载、SHA、current/previous 与回滚
```

业务方只依赖 `:lynx-shell` 或发布后的 AAR，不需要另外接 OTA SDK。
Runtime 接线还位于 `src/main/kotlin/com/example/lynxshell/ota/`，含 `LynxOtaRuntime`、`LynxOtaConfig` 与 epoch 隔离的 `OtaPageRefreshGate`；Core 的 `OtaSelection/OtaSdk` 负责身份和持久决定。
`android/lynx-capacitor` 尚未加入默认 `settings.gradle.kts` 和 Sample，必须由宿主显式接入。

### iOS

```text
ios/
├── LynxShellKit.podspec                Router、容器、Bridge、Provider、转场 Module
├── LynxShellKit/                       Shell Runtime、Router、容器、Bridge、转场
├── LynxMapKit/LynxMapKit.podspec       独立地图能力 Module
├── LynxMapKit/                         lynx-map、AMap Provider、Search、Location
└── OtaIOSSDK/Sources/OtaIOSSDK/         编进 LynxShellKit 的内部 OTA 源码
```

业务方接入 `LynxShellKit` 时会通过 Pod 依赖带入 `LynxMapKit`；需要单独使用地图能力的宿主
也可以显式声明 `pod 'LynxMapKit', :path => 'LynxMapKit'`。Shell 只调用
`LynxMapModuleRuntime` 做 Config 注册和隐私配置，不编译地图实现或直接声明高德 SDK。
`OtaIOSSDK/Sources` 保留 Swift 单测边界，不是业务方的第二个 OTA Pod。
`LynxShellKit/OTA/LynxSDKVersionResolver.swift` 解析可信 Lynx 资源/framework metadata；Core 只接收结果，不依赖 UIKit。
`ios/LynxCapacitorKit` 尚未加入默认 Podspec/Xcode Target，当前只交付原生能力源码。

### HarmonyOS

```text
harmony/
├── lynx_shell_kit/                     唯一可复用 HAR Module
│   └── src/main/ets/
│       ├── routing/                     Router、ArkUI Page Stack
│       ├── pages/                       LynxContainer
│       ├── provider/                    Bundle/资源 Provider
│       ├── module/                      LynxShellModule Bridge
│       └── ota/                         OTA Runtime、Store v3 CAS/Manifest、回滚
└── lynx_shell/                          Entry Demo，只直接依赖 HAR
```

`lynx_shell/oh-package.json5` 只声明 `@lynx/lynx-shell-kit`；底层 Lynx、Service、
XElement 和 OTA 依赖由 HAR 管理。
`ota/OtaUserContext.ets` 提供同步身份 box 与显式 captured context；`OtaSelection*.ets`、JSON/API 与 v3 Store 承载选择协议。Harmony 没有 candidate/trial。
`harmony/lynx_capacitor_kit` 尚未加入根 build profile 和 Entry Demo 依赖，当前只交付独立 HAR 源码。

## LynxCapacitor 当前边界

三端 `LynxCapacitorModule` 统一描述 40 个能力域、146 个方法，平台无等价实现时返回结构化
`UNSUPPORTED` 或 `UNAVAILABLE`，不返回假成功。当前 main 已包含三端源码与诊断 Bundle，但默认
Shell Sample 尚未完成构建图、Module 注册、权限和生命周期接线；不能把源码存在视为默认可用。

## 统一调用边界

```text
open(bundleUrl, params)                  -> 直接本地/HTTPS Bundle，不进入 OTA Store
open(lynxAppId, bundleName, params)      -> OTA Bundle，按 appId + bundleName 查找
```

启动或回到前台执行全量 `latest-bundle-list`；页面命中本地有效 Bundle 时立即渲染，
当前 appId 按 30 分钟门控后台检查；缺包、损坏或 SHA/size 不匹配时跳过门控，显示原生
Loading，完成下载、校验和原子激活后再创建 LynxView。首屏失败最多回滚一次。

原生 `registerOtaUserId` / `clearOtaUserId` 支持 install 前调用；身份变化使旧 epoch 失效。全量/定向/repair/主动刷新
统一携带 `versioncode`、`lynxSdkVersion` 与可选 userId。构建码独立于版本名称：Android 用 PackageInfo 与 resolved-variant BuildConfig，
iOS 用整数 CFBundleVersion 与可信 Lynx metadata，Harmony 用自身 BundleInfo 与 LynxEnv getter，请求固定 harmony。

Server 在用户/兼容过滤后比较 releaseSequence，full7 胜 gray6；policyRevision 控制决策新旧。State v3 的 ref selection 与 lastDecision
保存归属和决定，不增加用户字节副本；unknown 旧引用须重新确认。完整 100 包只变 1 时增量 1/复制 0，有界 GC 后回滚允许补下已回收对象。
Tab 普通切换 cache-only、后台不重建；身份变化和主动完成后重读 State，partial failure 不遮蔽已提交决定。

## 本次验证入口

- [iOS user-gray 报告](docs/ios-ota-user-gray-test-report.html)：83 Core＋4/4 UI，19 图。
- [Android user-gray 报告](docs/android-ota-user-gray-test-report.html)：87 tests / 0 skipped＋APK，非设备验收。
- Harmony：[当前报告](docs/harmony-ota-user-gray-test-report.html)、[host 测试](scripts/ota-user-gray/harmony-host-tests.mjs)、[Core 测试](scripts/ota-user-gray/harmony-core-tests.cjs)。host-final3 18/18（5真实HTTP）＋Core25/25，0失败/跳过；release HAR/App与静态90/0/0通过，设备按用户要求未验收。
- 独立Server本地 npm pack Contracts 产物联编125/125、0 skipped；只读历史序号preview为44 scopes/372条本地记录。没有npm发布、远程DB操作或部署。
- [OTA API 契约](OTA_SERVER_API_CONTRACT.md)；旧 `*-ota-store-v3-test-report.html` 仅为历史基础证据。

2026-09-15 当前分支已补充一轮设备冒烟：Android `LynxScreens_API35`（API 35）完成构建、安装、Page/Native Tab、中文切换和 Playground Bundle；iOS iPhone 18 Pro Max（iOS 27.0）完成临时 Simulator 构建、安装、OTA 首页和 Native Tab 启动；HarmonyOS DevEco `Pura 90`（HarmonyOS 6.1.1 API 24、HDC `127.0.0.1:5557`）完成 HAP 安装、OTA 首页和原生 ArkUI Tabs。三端 Sample 均未安装 LocalDiagnosticProvider，因此这些是宿主/Lynx 页面冒烟，不是监控事件 snapshot 或厂商云端验收；详细结果见 `docs/lynx-view-monitoring-v1/implementation.md`。

## LynxView 可插拔监控 G1

[研发方案 v1.0](docs/lynx-view-monitoring-v1/README.md) 定义三端 Page/Native Tab 性能、运行期 JS 异常、实际 Bundle 身份、可替换第三方 SDK 适配，以及构建调试材料归档和源码还原。
[G1 实现说明](docs/lynx-view-monitoring-v1/implementation.md) 对应当前分支的 Android、iOS、HarmonyOS 接线和 Playground 归档工具；不依赖 OTA Server/Admin，G2 第三方平台 Provider 仍未接入。

## 关键验证

```bash
python3 scripts/static_check.py
cd ios/OtaIOSSDK && swift test
cd ../../harmony
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleHar --mode module -p module=lynx_shell_kit@default --no-daemon
```

构建产物和本机令牌不进入仓库；详见根目录 `.gitignore`。
