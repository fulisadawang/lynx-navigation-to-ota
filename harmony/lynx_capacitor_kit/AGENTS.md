# AGENTS.md — HarmonyOS `lynx_capacitor_kit`

> 本文件面向 AI 编程代理，对 `harmony/lynx_capacitor_kit/` 及其子目录生效。它描述独立原生能力 HAR 源码，不改变 `harmony/lynx_shell_kit/AGENTS.md` 的 Router、Container、OTA 和转场职责。

## 模块定位与当前状态

`@lynx/lynx-capacitor-kit` 是项目自研的 HarmonyOS NativeModule HAR。它使用 HarmonyOS Kit 直接实现 Capacitor-compatible 页面协议，但不依赖上游 Capacitor Runtime、autolink 或生成式 registry。

当前 main 已包含 HAR 源码、module manifest、Hypium 测试和诊断 Bundle，但根 `harmony/build-profile.json5`、`lynx_shell/oh-package.json5` 和默认 LynxContainer 尚未依赖或注册它。接入必须显式完成 Module 加入、OHPM 依赖、modules Map 注册、权限、UIAbilityContext 和生命周期转发。

## 开工前必须读取

1. 根目录 `README.md`、`PROJECT_MAP.md`、`BRIDGE_CONTRACT.md`。
2. sibling Shell 规则：`harmony/lynx_shell_kit/AGENTS.md`。
3. 本目录 `oh-package.json5`、`build-profile.json5`、`src/main/module.json5`。
4. 协议目录：`LynxCapacitorCatalog.ets`、`LynxCapacitorEnvelope.ets`。
5. transport/runtime：`LynxCapacitorModule.ets`。
6. 独立音频 adapter：`LynxHarmonyAudioCapabilities.ets`。
7. 测试：`src/test/NativeCapabilityContract.test.ets`。
8. Android 基线：`android/lynx-capacitor/.../NativeCapabilityCatalog.kt`。

## 固定协议

- Module 名固定为 `LynxCapacitorModule`，结果事件固定为 `lynx-capacitor-result`。
- 同步查询只有 `getPlatform`、`getPluginHeaders`、`getCapabilityStatus`；业务调用统一走 `handleCall`。
- pluginId、methodName、顺序和总数必须与 Android 40 域、146 方法基线一致。
- 目录外方法必须返回 `UNIMPLEMENTED`，平台无等价实现返回 `UNSUPPORTED/UNAVAILABLE`，权限失败返回明确权限错误。
- listener add/remove/removeAll、长任务 save/event 和普通 callback 使用统一 envelope。
- 不把 HarmonyOS 专属扩展偷偷加入公共 catalog；需要扩展时先修改三端协议。
- 与 `LynxShellModule` 保持独立，Router、OTA、Page Stack 和转场仍归 `lynx_shell_kit`。

## ArkTS 与平台 owner

- 保持 ArkTS 严格类型，避免隐式 any、动态 prototype、运行时 monkey patch 和不支持的 TS 语法。
- `UIAbilityContext` 由宿主通过 `setHostContext` 注入，并在 Ability 销毁时 `clearHostContext`。
- App URL、push、前后台、backButton 等事件由 EntryAbility/LynxContainer 显式转发。
- UIContext、Picker、Dialog、Toast、Window、权限和 Want 操作必须使用当前有效宿主上下文。
- Camera、Audio、FileTransfer、Geolocation、Motion、Notifications 和 SQLite 的资源必须在 `destroy()` 中释放。
- CameraPicker/PhotoViewPicker 等对象按当前 SDK 类型构造，不用写入只读 profile 属性。

## 权限与错误语义

- `src/main/module.json5` 只声明 Module 自身确实需要的权限；业务用途文案、签名和系统授权仍由宿主负责。
- 模拟器缺少 CameraPicker、账户、传感器、通知服务或系统查看器时返回 `UNAVAILABLE`，不崩溃、不假成功。
- Android 不支持的方法在 HarmonyOS 也保持相同协议结果，除非三端契约明确升级。
- 真实联系人、日历、媒体、位置、通知和数据库内容不得进入日志、测试 fixture 或仓库。

## 构建边界

- package 名：`@lynx/lynx-capacitor-kit`，版本和 Lynx 依赖以 `oh-package.json5` 为准。
- 当前根 build profile 未登记该 Module。未完成显式接线前，不得声称默认 `assembleApp` 覆盖了它。
- 接入时需要同时更新根 build profile、Entry 依赖、LynxView modules Map 和 Ability 生命周期。
- `BuildProfile.ets` 属于构建生成/宿主配置边界，未经明确任务不要手改或覆盖。
- 不修改 `oh_modules`、`.hvigor` 或 build 输出替代源码修复。

## 安全与工作树

- 不写入 token、Cookie、证书、私钥、签名配置或真实用户数据。
- 不提交 HAR/HAP/App、模拟器沙盒、媒体、数据库和设备日志。
- 不修改 `harmony/lynx_shell_kit` 或 `harmony/lynx_shell`，除非任务明确要求宿主接线和 HDC 验收。
- 保留用户已有 BuildProfile 和签名配置，不 reset、不批量格式化大文件。

## 验证要求

1. `NativeCapabilityContract.test.ets` 校验 40 域、146 方法和统一 envelope。
2. 测试非法 payload、未知方法、权限拒绝、取消、不可用系统服务和 listener 清理。
3. 加入根 build profile 后单独构建 `lynx_capacitor_kit` HAR，再构建完整 App。
4. 使用 HDC 验证 Module 注册、诊断 Bundle、Ability 生命周期和 crash buffer。
5. Camera、Audio、Barcode、Contacts、Calendar、Notifications、Geolocation、Files 和 SQLite 分别记录模拟器/真机证据，不互相替代。

最终回复必须区分：ArkTS 静态通过、HAR 构建、Entry 接线、HDC 运行和物理设备能力，并明确所有 `UNSUPPORTED/UNAVAILABLE` 边界。
