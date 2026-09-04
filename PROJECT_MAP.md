# PROJECT_MAP

## 项目定位

`lynx-navigation-to-ota` 是独立的 Lynx 4.0 三端原生 Router + OTA 源码工程，并包含尚未接入
默认 Sample 的三端 `LynxCapacitorModule` 原生能力源码。
三端 Shell 业务方分别引入一个平台模块：Android AAR、iOS CocoaPods Module、HarmonyOS HAR。
本仓库不包含旧的 `LynxScreens-Android` 工程，也不依赖 Sparkling 原生 SDK。

## 顶层结构

```text
android/                  lynx-shell AAR、lynx-capacitor 源码 + 可运行 Sample
ios/                      LynxShellKit Pod、LynxCapacitorKit 源码 + 可运行 Sample
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
XELEMENT_INTEGRATION.md   Lynx 4.0 XElement 全量依赖清单
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
│   └── runtime/                        Lynx 4.0/XElement/Provider
└── src/main/kotlin/com/ota/android/sdk/
    └── 完整 Manifest、CAS 下载、SHA、current/previous 与回滚
```

业务方只依赖 `:lynx-shell` 或发布后的 AAR，不需要另外接 OTA SDK。
`android/lynx-capacitor` 尚未加入默认 `settings.gradle.kts` 和 Sample，必须由宿主显式接入。

### iOS

```text
ios/
├── LynxShellKit.podspec                唯一业务 CocoaPods Module
├── LynxShellKit/                       Router、容器、Bridge、Provider、转场
└── OtaIOSSDK/Sources/OtaIOSSDK/         编进 LynxShellKit 的内部 OTA 源码
```

业务方只声明 `pod 'LynxShellKit'`。`OtaIOSSDK/Sources` 保留 Swift 单测边界，
不是业务方的第二个 Pod。
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
