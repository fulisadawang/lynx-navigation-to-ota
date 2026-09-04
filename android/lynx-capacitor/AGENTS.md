# AGENTS.md — Android `lynx-capacitor`

> 本文件面向 AI 编程代理，对 `android/lynx-capacitor/` 及其子目录生效。它描述独立原生能力 Module，不改变 `android/lynx-shell/AGENTS.md` 的 Router、Container、OTA 和转场职责。

## 模块定位与当前状态

`lynx-capacitor` 是项目自研的 Android NativeModule 源码。名称保持 `LynxCapacitorModule`，用于兼容页面调用协议，但不依赖上游 Capacitor Runtime、Plugin Registry、autolink 或 codegen。

当前 main 已包含源码和诊断 Bundle，但默认 `android/settings.gradle.kts`、`android/app` 和 `lynx-shell` 尚未依赖或注册本 Module。源码存在不等于 Sample 已可调用。接入任务必须显式完成：

```text
加入 Gradle graph
→ 宿主依赖 Module
→ LynxView 注册 LynxCapacitorModule
→ 合并 Manifest/权限/FileProvider
→ 转发 Activity、权限和 App 生命周期
→ 运行诊断 Bundle 和设备测试
```

## 开工前必须读取

1. 根目录 `README.md`、`PROJECT_MAP.md`、`BRIDGE_CONTRACT.md`。
2. sibling Shell 规则：`android/lynx-shell/AGENTS.md`。
3. 本目录 `build.gradle.kts`、`consumer-rules.pro`、`src/main/AndroidManifest.xml`。
4. 协议目录：`NativeCapabilityCatalog.kt`。
5. transport/runtime：`LynxCapacitorModule.kt`、`LynxCapacitorRuntime.kt`、`NativeCapabilityDispatcher.kt`。
6. 具体能力：所有 `Native*Capabilities.kt`、相机/扫码/视频 Activity 与 FileProvider 契约。

## 固定协议

- Module 名固定为 `LynxCapacitorModule`。
- 结果事件固定为 `lynx-capacitor-result`。
- 对外只有四个 transport 入口：`getPlatform`、`getPluginHeaders`、`getCapabilityStatus`、`handleCall`。
- Android `NativeCapabilityCatalog.kt` 是三端 pluginId、methodName、顺序和方法总数的事实源。
- 当前契约为 40 个能力域、146 个方法；变更必须同步 iOS/Harmony catalog、诊断 Bundle、测试和 README。
- `handleCall` 接收 JSON payload，结果使用统一 envelope；禁止每个能力自行发明 callback 结构。
- 平台无等价能力时返回 `UNSUPPORTED`、`UNAVAILABLE` 或更精确错误码，不返回空对象或假成功。
- 原始 NativeModule transport 与 `LynxShellModule` 是两个独立协议，不互相改名、转发或吞并。

## 实现边界

### Activity、权限与生命周期

- UI、Window、Dialog、Camera、Barcode 和媒体操作必须绑定当前有效 Activity，并在主线程执行。
- 权限申请由 `NativePermissionCoordinator` 统一收口，不能让每个 capability 自建 requestCode 状态。
- 宿主必须转发 Activity Result、权限结果、App URL、push 和前后台事件；Module 不创建隐藏全局 Activity。
- Activity/Module 销毁时清理 listener、event sender、下载任务、传感器、播放器、录音器和数据库连接。
- 不把 Context、Activity、Cursor、Bitmap、Uri 或原生对象直接塞进 JSON callback。

### 文件、网络与媒体

- 文件路径必须限制在宿主允许目录，外部分享走 `FileProvider`；禁止拼接任意绝对路径。
- HTTP/FileTransfer 需要状态、取消和失败结果；不能只返回 operationId 后丢失任务生命周期。
- CameraX、ML Kit、录音、播放和视频 Activity 均属于本 Module，不得复制到 Shell Container。
- 长任务和 listener 必须支持取消/移除；Module destroy 后不得继续向旧 LynxContext 发事件。

### 能力目录

- `state=native/partial/unsupported` 描述真实实现程度，不能因为方法在 catalog 中就标记为可用。
- `implementedMethods` 必须与 dispatcher 实际分支一致。
- 新增能力先更新 Android catalog 和 envelope，再实现平台 adapter，最后同步另外两端。
- 不在页面层解析 Android 专属异常；统一转换为稳定 code/message/data。

## 构建约束

- `compileSdk=36`、`minSdk=26`、Java/Kotlin 21。
- Lynx 4.0 使用 `compileOnly`，宿主 Shell 提供 Runtime，避免打包第二份 Lynx。
- CameraX、ML Kit、AndroidX 版本以当前 `build.gradle.kts` 为准，未经明确授权不升级。
- 当前默认根工程没有 `include(":lynx-capacitor")`。在未显式接入前，不得声称 `:lynx-capacitor:testDebugUnitTest` 或 Sample 构建已经执行。

## 安全与工作树

- 不写入 token、Cookie、证书、私钥、服务端密钥或真实用户数据。
- 不提交 APK、Gradle cache、拍摄媒体、数据库、设备日志和权限快照。
- 不修改 `android/lynx-shell` 或 `android/app`，除非任务明确要求宿主接线或设备验收。
- 保留用户已有改动，不 reset、不批量格式化无关能力文件。

## 验证要求

协议或单能力修改至少验证：

1. catalog 域/方法数量和三端顺序一致。
2. payload 非法、未知 plugin/method、权限拒绝、取消、不可用设备均返回结构化失败。
3. listener add/remove/removeAll 和 Module destroy 无残留回调。
4. 加入宿主构建图后运行 `:lynx-capacitor:testDebugUnitTest` 和 Sample Debug 构建。
5. Camera、Audio、Barcode、Geolocation、通知、文件和 SQLite 必须在 emulator/device 单独验收，静态分支存在不能替代运行态。

最终回复必须区分：源码验证、Gradle 构建、宿主注册、设备能力和未覆盖权限场景。
