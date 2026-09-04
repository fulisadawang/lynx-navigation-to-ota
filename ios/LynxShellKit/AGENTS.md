# AGENTS.md — iOS `LynxShellKit`

> 本文件面向 AI 编程代理，对 `ios/LynxShellKit/` 及其子目录生效。与仓库根规则冲突时遵守更高层级规则；本文件只补充 iOS CocoaPods Module 的局部边界。

## 模块定位

`LynxShellKit` 是业务方唯一需要接入的 iOS CocoaPods Module。它拥有：

- UIKit Router、真实 `UINavigationController` 页面栈；
- `LynxContainerViewController`、Provider、GlobalProps 和生命周期；
- `LynxShellModule`、Storage、消息、媒体 Bridge；
- 自定义转场、共享元素、Open Container、Sheet 和侧滑返回；
- 与内部 `OtaIOSSDK/Sources/OtaIOSSDK` 的 OTA Runtime 接线。

`ios/OtaIOSSDK` 不是业务方需要额外声明的第二个 Pod；其 Sources 由 `LynxShellKit.podspec` 编入 Module，并保留独立 Swift Package 测试边界。`ios/LynxShellSample` 是 Sample App，不属于本目录。

`ios/LynxCapacitorKit/` 是 sibling 原生能力源码，当前尚未加入 `LynxShellKit.podspec` 或默认 Xcode Target。它不属于 Shell/OTA 实现；任务明确涉及该模块时先读 `ios/LynxCapacitorKit/AGENTS.md`，再显式决定 Pod/Target、Module 注册、权限和宿主生命周期接线。

## 开工前必须读取

按任务相关性读取：

1. 根目录 `PROJECT_MAP.md`、`ARCHITECTURE.md`。
2. `ios/LynxShellKit.podspec`、`ios/README.md`。
3. 接入/路由：`MODULE_INTEGRATION.md`、`ROUTER_CONTRACT_V1.md`、`ROUTING.md`、`NAVIGATION_README.md`。
4. Bridge：`BRIDGE_CONTRACT.md`。
5. 转场：`TRANSITIONS_README.md`。
6. OTA：`ios/OtaIOSSDK/README.md`、`Package.swift` 和相关 Tests。
7. 验证：根目录 `VALIDATION.md` 和最新 iOS HTML 报告。
8. 跨到原生能力层时：`ios/LynxCapacitorKit/AGENTS.md` 和 `LynxNativeCapabilityCatalog.swift`。

文档、代码和运行结果冲突时，以当前 Swift/Objective-C 源码、Podspec、Xcode 工程和最新运行证据为准。

## 目录与职责

```text
Bridge/       NativeModules、媒体 Bridge
Container/    LynxContainerViewController、Tab generation
Model/        页面请求和转场协议
OTA/          LynxShellKit 与 OtaIOSSDK 的适配层
Resource/     Bundle Provider、prepareRoute 缓存
Routing/      Router、原生栈、结果、恢复
Runtime/      GlobalProps、消息中心
Transition/   animator、共享元素、Sheet、手势、首屏门禁
UI/           通用错误态和必要 Loading
Native/       Objective-C 原生 Runtime 接线
```

不要把 `LynxShellSample` 的 Launcher、TabBar 或测试按钮复制进 Module。不要把 `OtaIOSSDK` 再包装成第二套业务公开接口。

## 不可破坏的架构约束

### 1. 页面和导航栈

- 一页 Lynx 对应一个真实 `LynxContainerViewController`。
- 默认使用业务宿主提供的 `UINavigationController`；Module 不创建全局单例 Window。
- `LynxRouter.install` 只安装一次 Router/OTA 依赖和 Home Handler。
- Direct Bundle 与 OTA Bundle 的身份边界固定：`bundleURL` 不等于 `lynxAppId + bundleName`。
- Router/Scene 恢复只持久化逻辑 entry、routeKey、session 和参数，不持久化沙盒绝对路径或活体 UIViewController。
- `launchMode`、高级 pop、页面结果和 Home Handler 语义必须与 Android/Harmony 公共契约一致。
- 系统导航栏是否显示由宿主和页面请求决定；通用 Lynx Bundle 默认 edge-to-edge，不额外叠加假导航栏。

### 2. OTA Store v3

- 内部 OTA 核心在 `ios/OtaIOSSDK/Sources/OtaIOSSDK`，LynxShellKit 只做 Router、容器、首屏健康确认、Tab 和 lease 接线。
- App ID 作用域 CAS、完整 Manifest、原子 State 和 GC roots 语义不得在适配层被改写。
- embedded Bundle 直接读取 App Bundle URL，不复制到 Application Support。
- State 不保存下载 Bundle 绝对路径；页面使用 `PreparedOtaBundle + lease`。
- 同一导航 session 通过 NavigationSnapshot 固定 Manifest；子页不得重新读取 current 造成版本漂移。
- Native Tab 只读 current，不消费 candidate、不因切换联网；主动刷新成功后再重建 generation。
- candidate 只有 pending/trial/healthy promote 流程；首屏失败丢弃 candidate，不回滚稳定 current。
- 首屏失败最多回滚一次 previous/embedded，禁止无限循环。
- 修改 OTA 契约时必须同步修改 OtaIOSSDK Tests、README 和三端协议文档。

### 3. 原生转场

- 一次跳转只有一个动画所有者。显式 `transition/routeType` 后，`ShellTransitionCoordinator` 和 `ShellNavigationAnimator` 必须独占 push/pop/fallback。
- 普通横向页面的系统 interactive pop 与壳 edge/full-screen pan 必须互斥，不能同时驱动。
- 共享元素和 Open Container 的 selector、真实 UIView、快照、矩形、圆角、阴影和 progress 都由 UIKit 主线程处理。
- `wx://bottom-sheet`：iOS 15+ 使用 `UISheetPresentationController`；iOS 13/14 才走壳 fallback。
- `wx://hero-sheet`：普通全屏透明 VC + 来源页 backdrop；Lynx 页面负责内容入场、滚动、导航渐变和下拉关闭。不要映射成 UIKit custom detent。
- selector/snapshot 失败时走壳内 `fade/slide/none`，不能重新落回 UIKit 默认 animator。
- `markTransitionReady` 只表示业务 ready；最终仍需首屏、layout 和 selector 门禁。
- Reduce Motion、交互取消、旋转/重建和栈批量操作必须有明确终态。

### 4. Bridge、线程与生命周期

- UIKit、Router、LynxView 和转场操作在 MainActor/主线程执行。
- 网络、磁盘、SHA 和 OTA 同步不得阻塞主线程。
- NativeModules callback 使用 JSON 可编码的 Foundation 类型；不要返回活体 UIKit/Lynx 对象。
- 原始 Module 以 `code=0` 表示成功；Playground wrapper 才归一化为 `code=1`。
- `LynxFirstScreenObserver` 必须绑定 load generation；旧 Bundle 的迟到回调不能标记新页面 ready。
- 释放顺序：取消 Provider/任务 → 移除或销毁 LynxView → 关闭 OTA lease → 清理手势和 observer。
- 图片/字体等首屏后的普通资源错误不能自动回滚整个 Release。

### 5. Pod 与依赖

- `LynxShellKit.podspec` 是业务接入事实源；未经明确授权不要创建第二个公开 Pod。
- Lynx/PrimJS/Service/XElement 版本保持项目冻结值，不自行升级或混入 nightly。
- 保留 `-ObjC` 和 XElement AutoRegistry 所需链接参数。
- 不直接修改 `Pods/`、DerivedData、`.build/` 或生成的 Xcode 文件来“修复”源码问题。
- Objective-C `Native/` 与 Swift Module 的公开符号必须保持可编译互操作。

## 安全与工作树

- 不把 clientToken、Cookie、签名 URL、请求头、证书或私钥写入源码、测试、xcconfig、日志和文档。
- 本地 OTA 配置只能通过测试进程环境或未跟踪配置注入。
- 不提交 Pods、DerivedData、xcresult、App/IPA 和生成 Fixture 二进制。
- 保留用户现有 Xcode 工程、Podfile 和转场协调器改动；禁止 reset/checkout 覆盖。
- 不修改 `ios/LynxShellSample`，除非任务明确要求 Demo 或 Simulator 验收。
- 不隐式编译或注册 `ios/LynxCapacitorKit`；默认 Podspec/Xcode Target 尚未包含它。

## 修改后的最低验证

```bash
# OTA Swift Package 测试
cd ios/OtaIOSSDK
swift test --no-parallel

# 根目录 Android/iOS 静态门禁
cd ../..
python3 scripts/static_check_android_ios.py --quiet

# Simulator 构建（使用当前 workspace/scheme）
xcodebuild -workspace ios/LynxShell.xcworkspace \
  -scheme LynxShell \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO build
```

涉及 Router、容器、Tab、转场、侧滑、首屏、OTA 回滚或 Scene 恢复时，必须补 Simulator/device 运行态证据。记录设备、系统、Bundle/Release 身份、请求计数、截图或 xcresult；条件跳过必须与失败分开报告。

## 交付说明

最终回复必须说明：

- 改动属于 LynxShellKit 还是内部 OtaIOSSDK；
- 是否改变公开 Pod/Router/Bridge/转场契约；
- 执行了哪些 Swift、静态、Xcode 和运行态验证；
- iOS 真机、签名包、低磁盘等未覆盖边界；
- 是否同步 README、协议和 Obsidian 长期文档。
