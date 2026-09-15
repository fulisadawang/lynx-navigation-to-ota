# Lynx Navigation to OTA

`lynx-navigation-to-ota` 是一套面向业务 App 的 Lynx 4.1 三端原生宿主工程。它把 Runtime、原生页面容器、Router、NativeModules、XElement、OTA Store v3 和页面转场放进可复用的 Android、iOS、HarmonyOS Module，同时保留可以直接运行的三端 Sample 与 ReactLynx Playground。

这个仓库解决的不是“如何打开一个 Lynx Bundle”这么小的问题。它解决完整链路：

```text
业务路由 / 原生 Tab
        ↓
LynxRouter + Native Page Stack
        ↓
Direct Bundle 或 OTA Bundle
        ↓
Provider / Store v3 / NavigationSnapshot
        ↓
LynxView + GlobalProps + NativeModules + XElement
```

当前主线直接使用 Lynx 4.1.0，PrimJS 使用官方组合 4.1.1。项目借鉴 Sparkling Playground 的页面组织方式，但不依赖 Sparkling 原生 SDK，不使用 autolink 或 codegen 注册宿主能力。

## 现在包含什么

- Android Activity-first、iOS `UINavigationController`、HarmonyOS ArkUI Router 三套真实原生页面栈。
- 本地资源、直接 HTTPS Bundle 和 OTA Bundle 三种明确加载路径。
- Store v3：完整 Manifest、App ID 作用域 SHA-256 CAS、原子 State、回滚、lease 和 Mark-and-Sweep GC。
- 原生用户注册、full/gray 选择、原生构建号与 Lynx Runtime 兼容校验；兼容 full V7 胜过 gray V6。
- 原生 Tab 承载：Android Fragment、iOS UIViewController、HarmonyOS ArkUI Tabs。
- Android/iOS 原生转场：基础转场、Skyline routeType、共享元素、Open Container、BottomSheet、heroSheet 和跟手返回。
- `LynxShellModule`：导航、页面结果、消息、隔离存储、AppInfo、媒体和 OTA 诊断。
- Lynx 4.1 XElement 全量接入和统一 Runtime 初始化，包含实验性 Video。Android AnimaX 宿主适配
  单独维护在 `codex/lynx-4.1-animax` 分支，当前升级分支不显式接入 `animax-view`。
- 本地 OTA Server、100 Bundle Golden Fixture、故障注入、三端测试报告和磁盘 Inspector。
- 三端 `LynxCapacitorModule` 源码，覆盖 40 个能力域、146 个方法的统一调用契约。

## 平台矩阵

| 平台 | Shell Module | 默认页面模型 | Native Tab Demo | OTA Store | LynxCapacitor 当前状态 |
|---|---|---|---|---|---|
| Android | `android/lynx-shell` AAR | 一页一个 `LynxShellActivity` | Fragment + BottomNavigation | v3，Android/iOS 可选 candidate | `android/lynx-capacitor` 源码已合入，尚未加入默认 `settings.gradle.kts` 和 Sample |
| iOS | `LynxShellKit` CocoaPods Module | `UINavigationController + LynxContainerViewController` | UITabBarController + UIViewController | v3，Android/iOS 可选 candidate | `ios/LynxCapacitorKit` 源码已合入，尚未加入默认 Podspec/Xcode Target |
| HarmonyOS | `@lynx/lynx-shell-kit` HAR | ArkUI `LynxContainer` Page | ArkUI Tabs | v3，仅 current/previous | `@lynx/lynx-capacitor-kit` 源码已合入，尚未加入默认 build profile 和 Entry Demo |

`LynxCapacitorModule` 目前是独立原生能力交付，不是默认 Shell 已注册能力。业务接入前必须显式把对应 Module 加入构建图、注册到 LynxView，并补宿主权限和生命周期接线。README 不把“源码存在”写成“默认 Sample 已可用”。

## 项目结构

```text
lynx-navigation-to-ota/
├── android/
│   ├── lynx-shell/                 Router、Activity 容器、Bridge、转场、OTA AAR
│   ├── lynx-capacitor/             独立原生能力 Module 源码
│   └── app/                        Android Sample
├── ios/
│   ├── LynxShellKit/               Router、UIViewController、Bridge、转场
│   ├── OtaIOSSDK/                  编进 LynxShellKit 的内部 OTA 源码与 Swift Tests
│   ├── LynxCapacitorKit/           独立原生能力 Module 源码
│   └── LynxShellSample/            iOS Sample
├── harmony/
│   ├── lynx_shell_kit/             可复用 Shell HAR
│   ├── lynx_capacitor_kit/         独立原生能力 HAR 源码
│   └── lynx_shell/                 HarmonyOS Entry Demo
├── playground/                     ReactLynx 多 Bundle Playground
├── examples/                       页面侧 NativeModules 类型声明与接入示例
├── scripts/                        静态门禁、Bundle 同步、OTA Fixture 与故障脚本
├── docs/                           API 页面、测试用例、截图和三端报告
├── PROJECT_MAP.md                  代码与数据流索引
├── MODULE_INTEGRATION.md           三端 Shell Module 接入
├── ROUTER_CONTRACT_V1.md           Native Page Stack 语义
├── BRIDGE_CONTRACT.md              LynxShellModule 协议
├── TRANSITIONS_README.md           Android/iOS 原生转场协议
├── OTA_SERVER_API_CONTRACT.md      OTA 服务端接口契约
└── VALIDATION.md                   分层验证入口
```

三端 Shell 与 Capacitor Module 都有面向 AI 编程代理的局部规则。Shell 规则负责 Router、Container、OTA 和转场，Capacitor 规则负责原生能力协议、生命周期与宿主接线边界：

- Android：[Shell AGENTS.md](android/lynx-shell/AGENTS.md) / [Capacitor AGENTS.md](android/lynx-capacitor/AGENTS.md)
- iOS：[Shell AGENTS.md](ios/LynxShellKit/AGENTS.md) / [Capacitor AGENTS.md](ios/LynxCapacitorKit/AGENTS.md)
- HarmonyOS：[Shell AGENTS.md](harmony/lynx_shell_kit/AGENTS.md) / [Capacitor AGENTS.md](harmony/lynx_capacitor_kit/AGENTS.md)

## 快速开始

### 环境

| 任务 | 建议环境 |
|---|---|
| Playground | Node.js 22/24、pnpm 10.26 |
| Android Shell | Android Studio、JDK 17、minSdk 24、compileSdk 35 |
| Android LynxCapacitor | JDK 21、minSdk 26、compileSdk 36，接入方需自行加入构建图 |
| iOS | Xcode、CocoaPods、iOS 13+ |
| HarmonyOS | DevEco Studio、HarmonyOS SDK 6.1.1(24)、OHPM/Hvigor |

### 1. 构建 Playground

```bash
cd playground
pnpm install
pnpm build
```

`pnpm build` 生成 `playground/dist/*.lynx.bundle`，并通过当前 Rspeedy 插件同步到 Android 和 iOS Sample。需要把单个主 Bundle 同步到三端时，可以使用：

```bash
./scripts/sync_bundle.sh /absolute/path/to/main.lynx.bundle
```

三端统一逻辑地址：

```text
assets://bundles/main.lynx.bundle
```

### 2. Android

仓库没有提交 Gradle Wrapper。推荐用 Android Studio 打开 `android/`，或使用本机 Gradle：

```bash
cd android
gradle :lynx-shell:testDebugUnitTest --no-daemon
gradle :app:assembleDebug --no-daemon
```

Sample 只依赖 Shell Module：

```kotlin
dependencies {
    implementation(project(":lynx-shell"))
}
```

### 3. iOS

```bash
cd ios
pod install
open LynxShell.xcworkspace
```

Sample 只声明一个业务 Pod：

```ruby
target 'LynxShell' do
  pod 'LynxShellKit', :path => '.'
end
```

`LynxShellKit.podspec` 会把 Lynx 4.1、Service、XElement 和 `OtaIOSSDK/Sources` 一起编进同一个 Module。业务方不需要再引入独立 OTA Pod。

### 4. HarmonyOS

用 DevEco Studio 打开 `harmony/`，或执行：

```bash
cd harmony
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleHar --mode module -p module=lynx_shell_kit@default --no-daemon

/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleApp --no-daemon
```

Entry Demo 当前只依赖：

```json5
"@lynx/lynx-shell-kit": "file:../lynx_shell_kit"
```

不要只安装旧 HAP。涉及 rawfile Bundle 或 Module 更新时，应重新构建完整 App。

## 在业务 App 中安装 Shell

### Android

```kotlin
class App : Application() {
    override fun onCreate() {
        super.onCreate()

        LynxRouter.install(
            this,
            LynxOtaConfig(
                apiBaseUri = URI.create("https://ota.example.com"),
                hostApp = "capp",
                environment = "PROD",
                platform = "android",
                clientToken = secureRuntimeToken,
            ),
        )
    }
}
```

### iOS

```swift
let ota = LynxOtaConfiguration(
    apiBaseURL: URL(string: "https://ota.example.com")!,
    hostApp: "capp",
    environment: "PROD",
    clientToken: secureRuntimeToken
)

try LynxRouter.install(
    to: navigationController,
    otaConfiguration: ota
)
```

### HarmonyOS

```ts
const ota = new LynxOtaConfig('https://ota.example.com')
ota.hostApp = 'capp'
ota.environment = 'PROD'
ota.platform = 'harmony'
ota.clientToken = secureRuntimeToken

LynxRouter.install(this.context, ota)
```

如果业务不需要 OTA，可以不传 OTA 配置，只使用本地或直接 HTTPS Bundle。没有 client token 时，Runtime 保持 embedded-only，不会偷偷请求 OTA。

### 用户与原生版本上下文

三端原生宿主使用 `LynxRouter.registerOtaUserId(userId)` 注册、`clearOtaUserId()` 清除，可在 install 前恢复身份，避免先匿名请求再重复同步。
相同规范化身份不重复同步/重建 Tab；身份变化立即递增 epoch，旧请求、导航 session 和候选回调不能修改新身份 State。
注册不等待网络，返回值不代表下载完成；等待同步使用既有主动刷新入口。

新版 latest 的精确 query 为 `versioncode`、`lynxSdkVersion`、可选 `userId`，匿名省略 userId。
构建码是 `1..9223372036854775807` 的十进制字符串，与版本名称和 `buildNumber` 上报字段独立。

| 平台 | 构建码默认来源 | 实际 Lynx Runtime 来源 |
|---|---|---|
| Android | PackageInfo.longVersionCode / versionCode | Library resolved variant 生成 `BuildConfig.LYNX_RUNTIME_VERSION`；预编译 AAR 被宿主强换 Runtime 后不属于已认证组合 |
| iOS | 纯整数 CFBundleVersion；分段值须显式覆盖 | 可信 LynxResources.bundle / Lynx framework metadata，多个来源必须一致 |
| HarmonyOS | 宿主自身 BundleInfo.versionCode | 实际 HAR 的 `LynxEnv.getLynxVersion()`；请求固定 harmony，不再降级为 Android |

Server 先按用户资格和兼容范围过滤，再比较 releaseSequence：full7 胜 gray6，gray8 仅对有资格用户胜 full7。
policyRevision 控制决定新旧，更高修订可以授权更低序号的回滚。注册及匿名内置下载示例见
[Module 接入](MODULE_INTEGRATION.md)，wire 见 [OTA API 契约](OTA_SERVER_API_CONTRACT.md)。

## Bundle 的两种业务身份

Router 不猜 App ID，也不把 HTTPS URL 自动改造成 OTA Bundle。

| 模式 | 调用输入 | 加载方式 | 进入 OTA Store |
|---|---|---|---|
| Direct Bundle | App 内资源或完整 HTTPS URL | Provider 直接读取 | 否 |
| OTA Bundle | `lynxAppId + bundleName` | Store v3 解析已提交 current | 是 |

Android：

```kotlin
LynxRouter.open(
    context = activity,
    bundle = "assets://bundles/main.lynx.bundle",
    params = mapOf("from" to "native"),
)

LynxRouter.open(
    context = activity,
    lynxAppId = "10000001",
    bundleName = "main.lynx.bundle",
    params = mapOf("from" to "ota"),
)
```

iOS：

```swift
try LynxRouter.open(
    bundle: "main.lynx.bundle",
    params: ["from": "native"]
)

try LynxRouter.open(
    lynxAppId: "10000001",
    bundleName: "main.lynx.bundle",
    params: ["from": "ota"]
)
```

HarmonyOS：

```ts
await LynxRouter.open('assets://bundles/main.lynx.bundle', { from: 'native' })
await LynxRouter.openOta('10000001', 'main.lynx.bundle', { from: 'ota' })
```

完整 HTTPS URL 属于 Direct Bundle，不参与 Manifest、current/previous、页面 30 分钟检查或 OTA 回滚。

## OTA Store v3

### 更新时序

```text
App 启动 / 回到前台
        ↓
全量 latest-bundle-list
        ↓
整批校验 selection/directives，逐 App 先提交 lastDecision
        ↓
完整 Release Manifest（selected App）
        ↓
按 App ID 查询 SHA-256 CAS
        ↓
只下载缺失对象，校验 size 与 SHA
        ↓
原子发布 Object 和 Manifest
        ↓
最后提交 State.current，旧版本成为 previous
```

页面打开时：

- 本地 current 或 embedded baseline 有效，立即创建 LynxView。
- 命中远程 current 后，当前 App ID 按默认 30 分钟间隔做后台检查，不阻塞当前页面。
- 本地缺包、文件损坏或 SHA/size 不匹配时，跳过门控，显示原生 Loading 并定向修复。
- 首屏失败最多回滚一次，不做无限循环。
- Native Tab 普通切换 cache-only，不联网；普通后台检查不重建实例。身份变化和主动刷新完成后按有效 epoch 重读 State，partial failure 不能遮蔽其他 App 已提交的更新或撤销。

### 磁盘结构

```text
<private-app-storage>/lynx-ota-store/apps/<lynxAppId>/
├── state.json
├── embedded.json                  # 逻辑身份，不含 Bundle bytes
├── manifests/<manifestId>.json    # 完整 Manifest
├── objects/<sha前两位>/<sha>.lynx.bundle
└── transactions/<transactionId>/  # .part 与事务日志
```

关键规则：

- CAS 按 App ID 物理隔离，不跨 App ID 共享对象。
- Manifest 是完整快照，不让客户端维护长期 patch 链。
- embedded Bundle 直接读取 APK assets、iOS App Bundle 或 HarmonyOS rawfile，不复制进 Store。
- State 是唯一激活点，页面永远不读取未完成 transaction。
- State v3 的引用保存 selection，State 保存 selectionSchemaVersion 与 lastDecision（audience/context 摘要、revision、action、目标）；不写原始 userId，不创建用户 Bundle 副本目录。
- 新模式下旧 v3 unknown 引用须等 Server 确认；所有 remote 读取都校验身份与 code/SDK 范围。明确 embedded 指令在冷启动后仍阻断旧 remote。
- `current + previous + candidate + active lease + transaction` 组成 GC roots。
- Android/iOS 可以选择 candidate/trial；HarmonyOS 明确不启用 candidate。

100 个 Bundle 只有一个变化时，V2 Manifest 仍有 100 条，但网络/对象只新增 1，未变对象复制 0 次。
GC 保留有界，不无限保存历史版本；回滚目标旧 050 已被回收时，允许补下缺失 1 个并复用其余 99 个。
基础用例见 [OTA Store v3 测试用例](docs/lynx-ota-store-v3-test-cases.md)，本次选择证据见下方当前报告。

## Native Tab

Module 提供容器能力，不接管业务 TabBar 设计：

| 平台 | Demo 承载 |
|---|---|
| Android | `Fragment + BottomNavigation` |
| iOS | `UITabBarController + UIViewController` |
| HarmonyOS | `ArkUI Tabs + LynxTabContainer` |

共同规则：

- Tab 实例第一次创建时只读已提交 current 或 embedded baseline。
- Home/Settings 普通切换不触发 latest、Manifest 或 Bundle 请求。
- 后台发现新版本时，当前实例继续使用旧 Snapshot。
- 身份变化及主动刷新完成后，宿主在有效 epoch 内 reset Snapshot、递增 generation，从已提交 State 重读；部分失败仍显示已提交决定，但不伪报整批成功。
- 页面和 Snapshot 分别持有 lease，GC 不会删除仍在显示的对象。

## Router 与页面通信

三端统一的是语义，不是平台对象：

```text
Android    Activity Task
iOS        UINavigationController
HarmonyOS  ArkUI Router
```

公共能力包括：

- `open`、`replace/redirect`、`pop/back`、`popTo`、`closeAll`、`reLaunch`
- `push`、`singleTop`、`clearTop`、`singleTask`
- `activePages`、`getNavigationState`
- `closeWithResult`、`consumeNavigationResult`
- `broadcast`、`sendToPage`、`emitToNative`
- `prepareRoute`、`cancelPreparedRoute`
- `markTransitionReady`、`getTransitionState`
- `deleteOtaBundles`、`deleteAllOtaBundles`、磁盘 Inspector

ReactLynx 页面优先使用 [playground/src/lib/navigation.ts](playground/src/lib/navigation.ts) 的 typed wrapper。原始 NativeModule 以 `code=0` 表示成功，Playground wrapper 会归一化为 `code=1` 并保留 `nativeCode`，不要混用两套判断。

完整协议：

- [Router Contract](ROUTER_CONTRACT_V1.md)
- [高级导航](NAVIGATION_README.md)
- [Bridge Contract](BRIDGE_CONTRACT.md)
- [Scheme 与参数](ROUTING.md)

## 原生转场

Android/iOS 保持一页一个真实 Activity/UIViewController，并由原生协调器统一管理：

- `fade`、`slide`、`slideUp`、`zoom`、`none`
- `wx://upwards`、`wx://zoom`
- `wx://bottom-sheet`、`wx://hero-sheet`
- `wx://cupertino-modal`、`wx://cupertino-modal-inside`
- `wx://modal-navigation`、`wx://modal`
- 最多 8 个共享元素、shuttle、内置 rect tween
- Open Container 的矩形、圆角、颜色、阴影和双内容裁剪
- Android Predictive Back、兼容 edge 手势、iOS interactive pop

显式自定义转场只有一个动画所有者。目标 selector、快照、几何和进度都由原生主线程处理，不让普通 NativeModules 每帧往返 JS。

`heroSheet` 使用透明全屏 Activity/UIViewController，Lynx 页面自己控制底部入场、连续上滑到全屏、顶部导航渐变和下拉关闭。它不是把普通 BottomSheet 拉高。

HarmonyOS 当前保留 Router/PageTransition 行为，尚未接入 Android/iOS 同级的原生共享元素/Open Container 协调器。详细边界见 [TRANSITIONS_README.md](TRANSITIONS_README.md)。

## LynxCapacitor 原生能力 Module

仓库提供三个独立源码目录：

```text
android/lynx-capacitor
ios/LynxCapacitorKit
harmony/lynx_capacitor_kit
```

它们实现自有 `LynxCapacitorModule` transport，不链接上游 Capacitor Runtime。三端统一入口：

```text
getPlatform()
getPluginHeaders()
getCapabilityStatus()
handleCall(payloadJSON, callback)
```

能力目录以 Android 契约为基准，覆盖 40 个域、146 个方法，包括 Device、App、Preferences、Filesystem、Camera、Audio、Geolocation、Haptics、Notifications、StatusBar、SQLite 等。平台没有等价实现时返回结构化 `UNSUPPORTED` 或 `UNAVAILABLE`，不返回假成功。

当前边界：

- 三端源码、能力目录和诊断 Bundle 已进入仓库。
- Android 默认 Gradle graph、iOS Podspec/Xcode Target、Harmony root build profile 尚未接入这些 Module。
- 默认 Shell Sample 尚未注册 `LynxCapacitorModule`，也没有完成权限与宿主生命周期接线。
- `capacitor-module.lynx.bundle` 和 `capacitor-bridge-diagnostic.lynx.bundle` 已放入三端 Sample 资源，但只有宿主完成 Module 注册后才能得到真实原生结果。

这是一条独立接入工作，不属于 OTA Store v3 或 `LynxShellModule` 的隐式能力。

## XElement 与版本

| 项目 | Android | iOS | HarmonyOS |
|---|---|---|---|
| Lynx | 4.1.0 | 4.1.0 | 4.1.0 |
| PrimJS | 4.1.1 | 4.1.1 | 4.1.1 |
| 最低系统 | Android 24 | iOS 13 | compatibleSdk 13 |
| XElement | 11/11 Maven 产物 | 11/11 CocoaPods subspec | 10 类平台能力 |

HarmonyOS 的 Markdown、SVG、WebView 按官方 Harmony 接入方式独立注册，其余能力由核心 Registry 提供。完整列表见 [XELEMENT_INTEGRATION.md](XELEMENT_INTEGRATION.md)。

Android 4.1 的官方 `xelement` 聚合 AAR 仍可能传递携带 AnimaX 二进制；升级主分支只保留
现有 XElement 和 Video 的宿主注册，并在聚合结果中过滤 `animax-view`。需要 AnimaX JSON、字体、
图片或视频资源链路时，使用独立的 Android AnimaX 分支。

## 验证

先运行静态门禁：

```bash
python3 scripts/static_check.py
python3 scripts/static_check_android_ios.py --quiet
python3 harmony/scripts/check_harmony_shell.py --quiet
```

再按改动范围运行：

```bash
# Playground
cd playground
pnpm exec tsc --noEmit
pnpm build

# OTA Golden Fixture
pnpm ota:v3:fixture
pnpm ota:v3:fixture:verify

# Android
cd ../android
gradle :lynx-shell:testDebugUnitTest --no-daemon
gradle :app:assembleDebug --no-daemon

# iOS OTA
cd ../ios/OtaIOSSDK
swift test --no-parallel

# HarmonyOS HAR
cd ../../harmony
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleHar --mode module -p module=lynx_shell_kit@default --no-daemon
```

静态、单测、构建、模拟器和真机是不同证据层。某一层通过不能替代另一层。
本次 user-gray/versioncode 证据快照（2026-09-06）：

- [iOS 当前报告](docs/ios-ota-user-gray-test-report.html)：Core 83 项、最终 UI run 4/4、19 张截图。
- [Android 当前报告](docs/android-ota-user-gray-test-report.html)：87 tests、0 failure/error/skipped＋APK；HTML 已验收，不代表设备测试。
- [HarmonyOS 当前报告](docs/harmony-ota-user-gray-test-report.html)：host-final3 mode=all 为18/18（5项真实HTTP），Core25/25，均0失败/跳过；release HAR/App 构建通过，静态90/0/0。HTML展示验收与自动测试分开记录。
- Server：实际 npm pack Contracts 本地产物联编重跑125/125、0 skipped；只读 backfill preview 核实44 scopes/372条本地记录，不重排已有不可变序号。未发布npm、未连接远程DB、未部署。

用户已取消本次 Android/Harmony 模拟器测试，按代码、自动/真实 HTTP 协议测试、构建和 HTML 验收；真机本轮未验收。逐项证据和未覆盖边界见 [最终验收索引](docs/ota-user-gray-acceptance-matrix.md)，可运行 `node scripts/ota-user-gray/verify-delivery.mjs` 只读复核报告资源和产物哈希。
复现带真实 Server 的门禁时按 [fixture 联调说明](scripts/ota-user-gray/README.md) 配置专用 loopback 环境；未设置真实 Server 环境而出现 skipped，不能沿用报告的零跳过结论。
以下是**历史 Store v3 基础报告**，不是本次灰度功能的设备通过证明：

- [iOS Store v3 报告](docs/ios-ota-store-v3-test-report.html)
- [Android Store v3 报告](docs/android-ota-store-v3-test-report.html)
- [HarmonyOS Store v3 报告](docs/harmony-ota-store-v3-test-report.html)

## 文档入口

### 先读

- [PROJECT_MAP.md](PROJECT_MAP.md)，代码入口与数据流。
- [ARCHITECTURE.md](ARCHITECTURE.md)，三端分层和平台 owner。
- [MODULE_INTEGRATION.md](MODULE_INTEGRATION.md)，Shell Module 接入步骤。
- [VALIDATION.md](VALIDATION.md)，验证层级和命令。

### 协议

- [ROUTER_CONTRACT_V1.md](ROUTER_CONTRACT_V1.md)
- [BRIDGE_CONTRACT.md](BRIDGE_CONTRACT.md)
- [NAVIGATION_README.md](NAVIGATION_README.md)
- [TRANSITIONS_README.md](TRANSITIONS_README.md)
- [OTA_SERVER_API_CONTRACT.md](OTA_SERVER_API_CONTRACT.md)

### 平台与依赖

- [Android README](android/README.md)
- [iOS README](ios/README.md)
- [HarmonyOS README](harmony/README.md)
- [XElement 集成](XELEMENT_INTEGRATION.md)
- [兼容性](COMPATIBILITY.md)
- [安全边界](SECURITY.md)
- [官方源码映射](SOURCE_MAPPING.md)

### 可视化与测试报告

- [GitHub Pages API 文档](docs/index.html)
- [Bundle 路径说明](docs/lynx-bundle-paths.html)
- [OTA Candidate 指南](docs/lynx-ota-candidate-version-guide.html)
- [OTA Store v3 测试用例](docs/lynx-ota-store-v3-test-cases.md)
- 在线文档：<https://fulisadawang.github.io/lynx-navigation-to-ota/>

## 当前边界

- OTA 本地 Fixture 和 TEST 环境通过，不等于生产 CDN/TLS、签名发布包和所有物理设备已经认证。
- HarmonyOS Store v3 已实现，但 Harmony 原生共享元素/Open Container 仍是明确缺口。
- Demo 以新 Store v3 schema 为主，不负责线上 Store v2 沙盒的自动迁移。
- LynxCapacitor 三端源码尚未接入默认 Shell Sample，不能只看到 Bundle 按钮就认为原生能力已经注册。
- `worklet:onframe` 当前映射为原生声明式曲线，不执行任意 Skyline Worklet closure。
- 构建产物、本机 OTA token、OSS 凭证、签名配置和生成 Fixture 二进制不进入仓库。

要接入业务 App，先读 [MODULE_INTEGRATION.md](MODULE_INTEGRATION.md)。要改 OTA，先跑 Store v3 测试用例。要接入 LynxCapacitor，先完成三端构建图、Module 注册、权限和生命周期接线，再谈页面验收。
