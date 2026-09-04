# AGENTS.md — iOS `LynxCapacitorKit`

> 本文件面向 AI 编程代理，对 `ios/LynxCapacitorKit/` 及其子目录生效。它描述独立原生能力源码，不改变 `ios/LynxShellKit/AGENTS.md` 的 Router、Container、OTA 和转场职责。

## 模块定位与当前状态

`LynxCapacitorKit` 是项目自研的 iOS NativeModule 实现。`LynxCapacitorModule` 这个名称只用于页面协议兼容，不表示链接了上游 Capacitor Runtime、Plugin Registry、autolink 或 codegen。

当前 main 已包含 Swift 源码和诊断 Bundle，但默认 `LynxShellKit.podspec`、`project.yml`、Xcode Target 和 Sample 尚未编译或注册本目录。接入任务必须显式决定独立 Pod/Target 或并入宿主，然后补 Module 注册、Info.plist 权限、App/Scene 生命周期和设备验证。

## 开工前必须读取

1. 根目录 `README.md`、`PROJECT_MAP.md`、`BRIDGE_CONTRACT.md`。
2. sibling Shell 规则：`ios/LynxShellKit/AGENTS.md`。
3. transport：`Bridge/LynxCapacitorModule.swift`。
4. 协议目录和 envelope：`LynxNativeCapabilityCatalog.swift`、`LynxNativeCapabilityContract.swift`。
5. dispatcher/runtime：`LynxNativeCapabilityDispatcher.swift`、`LynxNativeCapabilityRuntime.swift`。
6. `Capabilities/` 下全部平台 adapter。
7. Android 事实源：`android/lynx-capacitor/.../NativeCapabilityCatalog.kt`。

## 固定协议

- Module 名固定为 `LynxCapacitorModule`，结果事件固定为 `lynx-capacitor-result`。
- `methodLookup` 只导出 `handleCall`、`getPluginHeaders`、`getPlatform`、`getCapabilityStatus`。
- pluginId、methodName、顺序和总数以 Android catalog 为跨端基线，当前为 40 域、146 方法。
- `handleCall` 只负责 transport；能力执行进入 runtime/dispatcher/adapter，不在 Module wrapper 堆业务分支。
- callback 和持久事件使用统一 envelope；`save=true` 的长监听结果走 GlobalEvent，普通结果走 callback。
- 无等价 API 时返回稳定 `UNSUPPORTED/UNAVAILABLE`，不因为方法声明存在就返回成功。
- 与 `LynxShellModule` 保持独立；不得把 Router、OTA、转场或页面栈职责迁入本目录。

## 实现边界

### UIKit 与生命周期

- UIKit、权限弹窗、状态栏、键盘、相机、媒体和分享在 MainActor/主线程执行。
- 网络、文件、SQLite、编码和长任务不得阻塞主线程。
- 宿主通过明确协议提供方向、状态栏、系统栏和键盘 owner；能力 adapter 不直接猜 Window/Scene。
- `destroy()` / runtime `release()` 必须关闭 listener、event sender、观察者、媒体、下载和数据库资源。
- App URL、launch URL、push、前后台和 back 事件由宿主 App/Scene 显式转发，不依赖隐藏 swizzle。

### 权限与系统配置

- Module 源码不拥有业务 Info.plist、entitlements、APNs、Background Modes 或隐私文案。
- 新能力必须列出宿主需要的 usage description、entitlement、delegate 和系统版本边界。
- Simulator 可用不代表真机权限、相机、麦克风、通知、Keychain 或生物识别通过。

### 能力目录

- `state=native/partial/unsupported` 必须反映真实 adapter，不得用 catalog 声明替代实现证据。
- 修改方法集合时同步 Android/Harmony catalog、诊断 Bundle 和 README。
- Foundation/UIKit 错误统一映射到稳定 code/message/data，不把 NSError、URLSessionTask 或原生对象直接返回页面。
- listener 必须有 add/remove/removeAll 和销毁兜底，避免旧 LynxView 收到事件。

## 构建边界

- 当前目录没有独立 Podspec，也不属于默认 Xcode Target。
- 未完成显式 wiring 前，不得声称 CocoaPods 安装、Xcode build 或设备运行覆盖了本目录。
- 接入时保留 `LynxShellKit` 作为唯一 Shell/OTA Module；是否新建独立 `LynxCapacitorKit` Pod 需要由任务明确决定。
- 不手改 Pods、DerivedData 或 project.pbxproj 生成内容来伪造源码接入。

## 安全与工作树

- 不写入 token、Cookie、证书、私钥、真实联系人、日历、媒体、定位或通知数据。
- 不提交 xcresult、App/IPA、DerivedData、模拟器沙盒和数据库。
- 不修改 `ios/LynxShellKit`、`OtaIOSSDK` 或 `LynxShellSample`，除非任务明确要求宿主接线。
- 保留用户现有 Xcode/Pod 改动，不 reset、不大范围格式化。

## 验证要求

1. 校验三端 40 域、146 方法的名称和顺序一致。
2. 测试 payload/envelope、未知方法、权限拒绝、取消、设备不可用和 listener 清理。
3. 完成 Pod/Target wiring 后执行 Swift parse、Xcode build 和模块注册测试。
4. Camera、Audio、Biometrics、Geolocation、Notifications、Contacts、Calendar、Files 和 SQLite 必须使用真机或明确标注 Simulator 限制。
5. 诊断 Bundle 必须显示 `getCapabilityStatus` 的真实 native/partial/unsupported 状态。

最终回复必须区分：源码存在、编译进入 Target、Lynx 注册成功、设备 API 成功和未配置宿主权限。
