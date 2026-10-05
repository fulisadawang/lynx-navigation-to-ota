# PROJECT_MAP

## 项目定位

`lynx-navigation-to-ota` 是独立的 Lynx 4.1 三端原生 Router + OTA 源码工程，默认 Sample 已完成
独立 `LynxCapacitorModule` 原生能力模块的源码装配；宿主构建与设备运行仍需单独验收。
三端 Shell 业务方分别引入一个平台模块：Android AAR、iOS CocoaPods Module、HarmonyOS HAR。
本仓库不包含旧的 `LynxScreens-Android` 工程，也不依赖 Sparkling 原生 SDK。

## Async Bundle 与中英文随包 OTA（2026-09-29）

当前工作根下的五个独立 Git 项目已改为**译文随代码 Bundle 同版本**的方案；此节记录代码所有权，
不改变本仓库的三端原生 Router + OTA 定位：

| 项目 | 负责内容 |
| --- | --- |
| `../LynxContracts` | 主 Bundle、Async Manifest 引用与资源能力门禁的共享契约 |
| `../LynxAppPackagesAndTemplates` | 以源码 JSON 编辑中英文；主入口与各 lazy 功能静态导入自己的双语资源，构建主/Async Bundle 和清单 |
| `../LynxOtaAdmin` | 只管理代码 Release、主 Bundle、Async 清单及发布/停发/回滚 |
| `../LynxOtaServer` | 主/Async URL、size、SHA、owner/requestKey 校验，Release 选择、灰度、回滚与持久化 |
| 本仓库 | Android/iOS/Harmony Store v3、Async 本地 CAS/Provider 寻址、宿主 locale/切语、页面 lease 与回收 |

代码 Release 可选引用 Async 清单；它不再声明 `i18nRequirement`，也没有独立 Catalog API、
Catalog 本地 Store 或 `__lynxI18n` 词典注入。中英文本在 Bundle 内，原生仅传当前 `locale`。
主包和全部 Async 文件在 Store v3 切换 current 前下载并校验；页面首次 lazy 从页面固定的
代码 Release 读取本地 Async，回滚恢复对应的主/Async 组合。没有 Async 的纯主包仍走原路径。
Android APK 内置 `10020000` 新验收版本由 `sidecarIndexAssetPath` 关联主包与三个 Async；
iOS/HarmonyOS 当前新增的 `10020000` 内置 baseline 仅有 HomePage，电商 lazy 以下载态 Store v3
为验收目标，不能把前者说成已支持内置 Async。三端资源能力头 `x-ota-resource-schema: 1`
继续保护含 Async 的 Release。HarmonyOS 本轮新增默认关闭的 candidate/trial 源码流程，构建和运行尚未验收。

旧 Catalog Release 的网络响应由三端拒绝。当前本地 TEST 验收按用户决定采用新双语版本并重装
旧测试安装；没有验证存量真实用户设备原地升级。五仓实施计划、官方插件失败证据与模板构建
结果见 [随包双语迁移计划](../LynxAppPackagesAndTemplates/templates/lynx-template/docs/INLINE_I18N_CATALOG_RETIREMENT_PLAN.md)
及 [本地工作流记录](../LynxAppPackagesAndTemplates/.workflow/lynx-bundled-i18n-retirement/final-report.md)。

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
`android/lynx-debug-tool` 是仅 Debug 构建使用的可选诊断 Module；它通过 Shell 的无 UI
诊断 SPI 读取有界的容器、Bundle、GlobalProps 和 LynxMonitor 事件。真实 SPI 位于 `src/debug`；
非 Debug variant 通过 `GenerateProductionSources` 移除共享源码中的显式调试块，Release AAR 和
`sourceReleaseJar` 都使用生产输入，不保留真实 SPI 或运行时空实现。Sample 调试安装入口位于 `app/src/debug`。
Runtime 接线还位于 `src/main/kotlin/com/example/lynxshell/ota/`，含 `LynxOtaRuntime`、`LynxOtaConfig` 与 epoch 隔离的 `OtaPageRefreshGate`；Core 的 `OtaSelection/OtaSdk` 负责身份和持久决定。
`android/lynx-capacitor` 已加入默认 Gradle graph，由 Sample 显式依赖、安装 Runtime 并注册。
Shell、能力模块和 Sample 使用 minSdk 26/JVM 17；构建 JDK 为 21、Gradle 8.11.1、AGP 8.9.1。Page/Tab
通过可选 NativeModuleHost 接线，Shell AAR 不直接依赖具体能力模块。
Page/Tab 的候选确认需要真实首屏和业务 `markOtaHealthy` 两个信号；首次启动维护清除遗留
TRIAL，普通同步保留本进程试运行。页面链固定到唯一进程快照和 lease，恢复或身份变化后
失效快照停止接收新页面，存活页面继续持有自己的资源。当前 Android Lynx 4.1 实际
`LynxModuleWrapper.destroy()` 会转发能力 Module 销毁，Android 沿用 SDK 链路。
Cap 提供公开 Host provider；Sample 将容器系统栏、方向和文字缩放适配到 Shell 的中性
系统 UI handle。状态查询不创建 UI Host 或申请权限。Android 执行结果和未覆盖项见
`docs/native-readiness-v1/android-test-report.html`。
原 Shell API 24 声明与 java.time API 26 的不一致已通过明确 API 26 基线纠正；API 26/36
实际宿主用例分别执行，完整结果以本轮报告为准。公开 Host 接口中的 LynxView 类型由
Shell 对同一 Lynx 4.1 Core 的 api 依赖导出，消费 App 不必重复声明 SDK。

### iOS

```text
ios/
├── LynxShellKit.podspec                Router、容器、Bridge、Provider、转场 Module
├── LynxShellKit/                       Shell Runtime、Router、容器、Bridge、转场
├── LynxMapKit/LynxMapKit.podspec       独立地图能力 Module
├── LynxMapKit/                         lynx-map、AMap Provider、Search、Location
└── OtaIOSSDK/Sources/OtaIOSSDK/         编进 LynxShellKit 的内部 OTA 源码
```

生产业务方继续依赖 `LynxShellKit` 并默认带入
`LynxMapKit`；本地 iOS OTA E2E Host 使用独立的 `LynxShellKitE2ECore.podspec`，复用 Shell 源码
但保持唯一 Core 模块名，以便 Simulator 测试不隐式解析到带地图的生产 Pod。该测试 Pod 不发布，
也不进入生产依赖图。需要单独使用地图能力的宿主仍可声明
`pod 'LynxMapKit', :path => 'LynxMapKit'`。Shell 只调用
`LynxMapModuleRuntime` 做 Config 注册和隐私配置，不编译地图实现或直接声明高德 SDK。
`OtaIOSSDK/Sources` 保留 Swift 单测边界，不是业务方的第二个 OTA Pod。
`ios/LynxShellDebugKit` 是仅 Debug configuration 引入的开发 Pod；它复用 Shell 诊断 SPI，
通过按 Scene 建立的 passthrough window 提供 App 内全局可拖动入口，不进入 `LynxShellKit` 的生产依赖图。
Shell 诊断声明与调用、DebugKit 的 Swift/ObjC 实现均受 `DEBUG` 条件保护；Sample Podfile 还显式
排除生产配置的诊断源码输入。发布产物检查见 `scripts/check_debug_tool_release.py`。
`LynxShellKit/OTA/LynxSDKVersionResolver.swift` 解析可信 Lynx 资源/framework metadata；Core 只接收结果，不依赖 UIKit。
`ios/LynxCapacitorKit.podspec` 是独立能力 Pod，普通 Sample 和 Core E2E Sample 均显式依赖。
App 启动先注册额外 Module，Shell 对全局及每个 Page/Tab 的 Config 都应用这些注册。
当前 iOS Lynx 4.1 不自动转发普通 NativeModule.destroy；宿主注册 onViewDestroy 后，
Shell 在换包、错误、退出时按真实 Context 释放能力，再销毁 LynxView。健康确认需要 SDK 首屏
与业务 markOtaHealthy 双信号；失败快照退休保留活体资源，恢复固定稳定 current。
本轮 36 项行为用例、证据层级和硬件限制见 docs/native-readiness-v1/。

### HarmonyOS

```text
harmony/
├── lynx_shell_kit/                     唯一可复用 HAR Module
│   └── src/main/ets/
│       ├── routing/                     公开Router、逻辑entries、CommandOptions
│       ├── transition/                  Navigation/NavPathStack adapter、Shared/Open/preset/proxy、预热token
│       ├── pages/                       LynxContainer
│       ├── provider/                    Bundle/资源 Provider
│       ├── module/                      LynxShellModule Bridge
│       └── ota/                         OTA Runtime、Store v3 CAS/Manifest、回滚
└── lynx_shell/                          Entry Demo，只直接依赖 HAR
```

`lynx_shell/oh-package.json5` 声明 `@lynx/lynx-shell-kit` 与独立的 `@lynx/lynx-capacitor-kit`；底层 Lynx、Service、
XElement 和 OTA 依赖由 HAR 管理。
`ota/OtaUserContext.ets` 提供同步身份 box 与显式 captured context；`OtaSelection*.ets`、JSON/API 与 v3 Store 承载选择协议。
Harmony `candidateActivationEnabled` 默认关闭，开启后 PENDING/TRIAL 与 SDK首屏、业务 markOtaHealthy 双信号确认共用唯一 State；旧 TRIAL 启动恢复、候选/稳定回退、NavigationSnapshot 与页面独立 lease 属于 Shell HAR。
`harmony/lynx_capacitor_kit` 已加入根 build profile 和 Entry Demo；Ability 注入宿主上下文，
Shell 的普通 Page/Native Tab 通过宿主注册表安装 Module，并在 Context 真正移除时释放。
当前没有 HarmonyOS Debug HAR；三端调试能力首版先覆盖 Android/iOS，HarmonyOS 保持现有
LynxMonitor 能力，不把未实现的 Debug Module 写成已接通。

## LynxCapacitor 当前边界

三端 `LynxCapacitorModule` 统一描述 40 个能力域、146 个方法，平台无等价实现时返回结构化
`UNSUPPORTED` 或 `UNAVAILABLE`，不返回假成功。默认 Demo 的构建图、Module 注册、权限和
必要生命周期已完成源码接线；verification.host 为 `configured_not_run`，构建和设备仍为
`not_run`。这不是所有 146 个方法都已运行验收。接线方式与边界见 [Demo 接入说明](CAPACITOR_DEMO_INTEGRATION.md)。

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

2026-09-30 上线前业务事件扩展：三端现有 Shell Module 增加 `reportBusinessEvent(group,name,attributesJSON,callback)`，监控 Core 统一记录 `business.event`。所有事件拥有顶层 `group`；原生系统分组由采集器填写、业务分组/名称自由传入。回执仅证明原生队列接受，厂商 Provider/后台交付仍需后续接入。接口、身份绑定与状态见 [业务桥接合同](BRIDGE_CONTRACT.md#业务事件与分组)。本轮未运行新增能力的编译、测试或设备验收。

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


## Android / iOS 原生媒体统一（2026-10-04）

Shell 的 chooseMedia/uploadFile/uploadImage/downloadFile/saveDataURL 五个旧 ABI 保留；
ShellMediaBridge 只负责中性宿主媒体接线与原有结果协议，实际选择/上传/下载/落盘归独立
Cap 媒体后端。Core 不反向依赖 Cap。Android 新增 LynxNativeMediaHost，由 DemoHost 安装；
iOS AppDelegate 在 bootstrap 前通过 LynxRouter.installMediaHandler 连接 Cap public facade。

两套入口使用 exact LynxContext 的共同 owner/runtime。Shell 先调用、Cap Module 后惰性
构造时不替换 owner；View 销毁出口也释放没有 Cap Module 实例的 legacy runtime。Android
所有 Activity/Tab View 销毁先过中性媒体 hook，再过 SDK；iOS继续使用已有注册的销毁hook。

图片/视频/混合选择由系统picker处理。预览复用 Camera.playVideo 与 FileViewer：Android
VideoView/MediaController、iOS普通AVPlayerViewController；NativeMedia图片预览使用Android内置
原生图片Activity/iOS Quick Look多项，支持本地图片数组及initialIndex；旧single FileViewer继续
使用系统ACTION_VIEW/Quick Look。Camera.chooseFromGallery source支持PHOTOS/CAMERA/PROMPT，
可直接相册/拍摄或显示原生来源菜单，拍摄后才按需申请权限。单次最多16项，direct limit0使用默认多选上限16，legacy count/maxCount
只接受1...16。新JS包入口为 @cclx/lynx-native-bridge/native-media，模板文档消费公共包，
不复制自绘picker/player。

源码与专项复审完成后已授权编译，Android/iOS最终宿主与本地模板Bundle已构建安装，
新Demo与iOS来源菜单可见；实际拍摄、多图滑动与完整媒体验收尚未完成。docs/native-readiness-v1/
旧六项报告是媒体修改前的软件证据，不代表媒体扩展后的完整回归。接口/预算/平台差异
及待执行验收见 docs/native-media-v1/；40域146方法和四transport未增加。Harmony 后续源码对齐见下一节，双端既有验收不能替代其运行证据。

## Harmony 软件能力对齐（2026-10-05，源码闭环与独立审查）

当前分支 `codex/harmony-native-parity` 从原生 PR20 的 `b5d649e` 创建。地图按用户最新指令延期；硬件和三端共同未配置的正式业务 Provider 如实返回不可用，不伪造成功。

- Cap HAR：SDK薄facade → exact LynxContext共享Runtime → Owner/真实Host → 有界NativeIO及平台能力adapter。Shell通过中性HostNativeModules SPI装配，保持独立依赖边界；Entry提供Ability/UIContext/Window及Ability前台与页面可见的联合getter。
- IO/存储：普通payload1MiB、内联512KiB、结果2MiB、文件20MiB；TaskPool处理bulk文件/编码，native异步网络/数据库共用并发2、等待16。SQLite返回columns/values、真实changes/lastId、只读打开、可靠分句和同DB串行，取消后等真实工作完成再close。
- 媒体：系统图片/视频选择与CameraPicker、自有ArkUI Video/Swiper图片预览、来源/方向/限制/标签/私有输出/相册保存参数；旧Shell媒体保持原ABI并消费同后端。ActionSheet复用可关闭原生菜单，不再依赖无法随owner关闭的旧系统ActionMenu。
- OTA/布局：Storev3保留CAS/Async/原子State/用户epoch/decimal revision，增加默认关闭候选、首屏+业务健康确认、失败来源退休与恢复；容器安全区以当前窗口vp坐标测量，真实UIContext density动态更新，键盘不计入系统安全区。
- 导航/转场：实际ShellNavigationHost+Navigation/NavPathStack承载，标题和业务导航Lynx自绘；Native proxy终态提交逻辑entries。Shared/Open/preset正反向、手势取消、source预捕与真实首屏/绘制门禁共用原生时钟，64MiB全局预算包含pending/临时mask/late释放，失败有live fallback。
- hero：透明全屏、[28,56,100]初始56元数据由Lynx管理surface/滚动，不裁剪为Native56vh；bottomSheet单独使用Native档位/遮罩/手势。普通与高级颜色领域保持既有Native ARGB/高级RRGGBBAA各自语义。
- 预热/命令：prepareRoute真实Provider bytes，4条/32MiB/30秒一次token，预热OTA不TRIAL、页面消费claimlease；命令animated/dedup实际消费，公开SDK reLaunch等真实清栈成功再打开fresh session。
- 生命周期：实际覆盖Page/Tab进入SDK background与owner hidden；取消恢复exactContext和lease。Window政策预捕前实际生效、返回当前栈顶恢复；默认保宿主沉浸布局与底部系统导航条。API13 nothing/none明确拒绝，API14+可用。
- 软件API源码闭环通过有界独立审查；61条手工用例全未执行。本轮无Harmony parse/typecheck/checks、HAR/App编译、设备或性能验收，不能描述为三端已经全部运行一致。
- 明确边界：NativeTab不计入Lynx entries/结果receiver；复杂共享洞父gradient/image无法完整复原；preset默认几何/曲线数值存在平台差异。主干双端旧运行证据保留为历史，不替代本轮。见[实施报告](docs/harmony-native-parity-v1/implementation-report.html)。
