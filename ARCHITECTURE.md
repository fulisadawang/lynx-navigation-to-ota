# 三端架构说明

## 1. 总体分层

```text
Native Launcher / Existing Business Router
                    ↓
       LynxRouteParser + LynxPageRequest
                    ↓
 Android Activity / iOS UIViewController / Harmony ArkUI Page
                    ↓
     Container + GlobalProps + XElement Runtime
                    ↓
 Template / Generic / Media Provider + Lynx Runtime
    ↓
      LynxShellModule / Host Capability Adapters
```

OTA 是发行层，不改变 Native Page Stack：

```text
lynxAppId + bundleName
        ↓
OTA Runtime current/SHA 热路径
        ├── 命中：立即交给容器，按 appId 后台定向检查
        └── 缺失/损坏：原生 Loading → latest-list → staging → size/SHA → current
                                                     ↓
                                               LynxView 创建
```

直接 HTTPS Bundle 不进入这条链路。启动/回前台的全量同步由宿主生命周期触发，页面 30 分钟
门控只作用于命中本地 Bundle 后的后台检查；首屏失败最多回滚一次。

业务路由只产生 `LynxPageRequest`，不直接创建或操作 `LynxView`。模型统一承载 Bundle URL、`initData`、`globalProps`、标题、全屏、导航栏、状态栏、方向、背景色、尺寸和调试 HTTP 开关。

## 2. 平台页面模型

### Android

- `LynxShellApplication` 完成进程级 Runtime 初始化；
- 一个 Lynx 页面对应一个 `LynxShellActivity`；
- Activity 只管理系统窗口、Material Toolbar、错误态、`LynxView` 挂载和销毁；
- `LynxContainerFactory`、Provider、Router、Bridge 独立。

### iOS

- `AppDelegate` / `SceneDelegate` 管 Runtime 与根导航；
- 一个 Lynx 页面对应一个 `LynxContainerViewController`；
- 使用系统 `UINavigationController`，保留原生 push/pop 和侧滑返回；
- Objective-C 薄层保留 Lynx 4.1 API 的直接调用形态，Swift 处理业务壳职责。
- OTA 源码随 `LynxShellKit.podspec` 一起编译进同一个业务 Module；`LynxOtaRuntime` 只向容器
  交付已经校验过的 current 文件，不把 staging/previous 路径暴露给页面。

### HarmonyOS

- `LynxAbilityStage` 初始化进程级图片缓存；
- `EntryAbility` 按 Service → `LynxEnv` → XElement 顺序初始化，并保存 `WindowStage` 与深链；
- `Index` 是原生 ArkUI 启动页；`LynxContainer` 是单页宿主；
- ArkUI Router 只传递强类型 `LynxPageRequest`，页面本身不重复解析外部 URL。
- OTA 主链是 `LynxOtaRuntime` → `ContentAddressedOtaStore`，旧 `ReleaseTransaction` 仅保留源码兼容物。
  请求及宿主身份均为 `platform=harmony`，不再使用 Android 兼容覆盖。Store 提供完整 Manifest、App ID 作用域 CAS、current/previous、
  lease 和原子 State；HarmonyOS 不加入 candidate。

## 3. Runtime 与 XElement

- Android：`LynxRuntimeInitializer` 注册 Image、Log、HTTP 等 Service；`XElementRuntime` 把 4.1 全量 Behavior（含 Video）装入每个 Builder；AnimaX 宿主接入由独立分支维护；官方聚合器可能携带其传递依赖。
- iOS：`LynxNativeRuntime` 配置全局 Runtime；XElement `Behavior` subspec 使用 AutoRegistry，`-ObjC` 防止静态链接裁剪，Video 已接入，AnimaX 延期。
- HarmonyOS：先注册 Log、DevTool、HTTP、Image Service，再执行 `LynxEnv.initialize`；Markdown 进程级初始化，SVG/WebView/Video 通过 `BehaviorRegistryMap` 注入每个 `LynxView`，其余能力由核心 Registry 提供。

## 4. 资源层

### OTA 选择与提交边界

原生 Router 的 `registerOtaUserId/clearOtaUserId` 更新身份 epoch；同身份重复注册不产生重复同步。
新版 latest query 固定为 `versioncode`、`lynxSdkVersion`、可选 userId，scope 仍是 env/hostApp/appId/platform。
Server 先校验用户资格及范围，再比较 releaseSequence，因此 full7 胜 gray6；policyRevision 则防止旧响应覆盖新决定，允许高修订回滚低序号。

| 平台 | 原生构建码 | Runtime 版本事实源 |
|---|---|---|
| Android | PackageInfo.longVersionCode / versionCode，不是 versionName | resolved variant 的 Lynx 组件生成 BuildConfig；预编译 AAR 被宿主强换 Runtime 未认证 |
| iOS | 纯整数 CFBundleVersion 或显式 versionCode | 可信 LynxResources.bundle / Lynx framework metadata，多源必须一致 |
| HarmonyOS | 自身 BundleInfo.versionCode | 实际 HAR 的 LynxEnv.getLynxVersion()，不采用固定 BUILD_NUMBER 或 Android 身份 |

State schema 仍为 v3；current/previous/candidate 引用携带 selection，State 保存 selectionSchemaVersion 与 lastDecision。
lastDecision 的 audienceKey/clientContextKey/revision/action/target 是选择约束，不是 bytes 的 GC root，也不保存 raw userId。
新模式拒绝 unknown 旧引用，重新确认后可以复用 CAS。full/gray 都重检 code/SDK/宿主范围，gray 额外重检 audience。

批次先校验全部 selection/directives，再逐 App 提交决定，最后独立下载；单 App 失败保留 partial result，不阻止其他 App 撤销落盘。
最终 State rename 必须再次校验 epoch 与决定。Android 显式传递 Executor 的 ThreadLocal snapshot，iOS 保留外层 TaskLocal；
Harmony 每次 async 调用显式传只读 context，不使用跨 await 的全局 operationContext。旧 lease.close 不受身份失效阻止。

完整 Manifest 不变成 patch 链；100 包只变 050 时新增下载/对象 1、复制 0。有界 GC 只保留引用、活体 lease 和未完成事务；
回滚到已 GC 的历史 050 可以补下 1 个，不承诺永久零下载。Harmony 不增加 candidate/trial。

Native Tab 普通切换 cache-only，普通后台更新不重建；身份变化和主动刷新完成后 reset Snapshot/generation 并重读已提交 State，
包括 partial failure。旧 epoch 的页面、回调及导航 session 不能借新 context 重试写操作。

当前证据及非设备边界见 [README 验证](README.md#验证)；历史 v3 报告不能替代本次 user-gray 验收。

### Provider 资源校验

三端 Provider 均遵守以下原则：

- 本地：拒绝空路径、绝对路径和 `..` 路径穿越，只读取 App 自身资源；
- 远程：默认 HTTPS、不限制 Host、2xx 状态、非空内容和 20 MB 最大体积；
- 生命周期：重试或页面销毁时取消旧任务，屏蔽过期回调；
- 失败：同时通知 Lynx 与原生错误页，不用空字节伪装成功。

HarmonyOS 额外拆分：

- `ShellTemplateResourceFetcher`：Bundle / SSR 数据；
- `ShellGenericResourceFetcher`：字体、图片和二进制资源；
- `ShellMediaResourceFetcher`：逻辑本地路径转 `resource://rawfile/`。

## 5. Bridge 层

页面只调用稳定的 `LynxShellModule`。当前提供 Router、Storage、AppInfo 最小闭环。登录、支付、定位、相机、相册等能力应新增独立 Adapter/Module，并在三端协议文档和 TypeScript 声明中同步，不应塞入容器页面。

## 6. Explorer 与 Sparkling 的合并边界

| 能力 | 采用方式 |
|---|---|
| Lynx Runtime / Service / View | 采用各平台 Explorer 的官方调用方式 |
| Provider / initData / globalProps | 按业务壳抽成稳定模型和独立实现 |
| Router / Context / Method 分层 | 借鉴 Sparkling Playground 的职责隔离 |
| Sparkling Playground 页面 | 作为 iOS 默认首页重新构建，不携带原生 SDK |
| Sparkling Runtime | 不进入默认 Lynx 4.1 主链路；NativeModules 由宿主手工实现 |
| Explorer 展示能力 | 不包含扫码、Recorder、测试列表、Showcase、GN 构建任务 |

Harmony Explorer 位于 Lynx monorepo 内，官方工程依赖本地源码 override、GN/CMake 与 Bundle 构建。业务壳改为标准 OHPM 依赖，只保留应用宿主必需部分。

## 7. 扩展原则

1. 页面不直接依赖 Activity、UIViewController、UIAbility 或底层 Bridge 实例。
2. 新增原生能力先更新 [BRIDGE_CONTRACT.md](BRIDGE_CONTRACT.md)，再实现三端并更新 TypeScript。
3. 权限、登录、支付等能力不得返回假成功。
4. Bundle 签名、缓存、灰度、回滚和 CDN 属于发行系统，应在 Provider 上层完成。
5. 多页面共享状态交给原生 Store / Native Module，不依赖单个 `LynxView`。
6. 外部深链不得直接决定账户、支付或权限状态。
