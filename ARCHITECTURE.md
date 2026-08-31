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
- Objective-C 薄层保留 Lynx 4.0 API 的直接调用形态，Swift 处理业务壳职责。
- OTA 源码随 `LynxShellKit.podspec` 一起编译进同一个业务 Module；`LynxOtaRuntime` 只向容器
  交付已经校验过的 current 文件，不把 staging/previous 路径暴露给页面。

### HarmonyOS

- `LynxAbilityStage` 初始化进程级图片缓存；
- `EntryAbility` 按 Service → `LynxEnv` → XElement 顺序初始化，并保存 `WindowStage` 与深链；
- `Index` 是原生 ArkUI 启动页；`LynxContainer` 是单页宿主；
- ArkUI Router 只传递强类型 `LynxPageRequest`，页面本身不重复解析外部 URL。
- `lynx_shell_kit` 内置 `LynxOtaRuntime` 与 `ReleaseTransaction`；宿主身份始终使用
  `platform=harmony`。在服务端尚未开放该枚举的过渡期，Demo 只把查询/Release 校验值设置为
  `serverPlatform=android`，不改变 AppInfo/GlobalProps；后端开放后删除该兼容值。
  OTA 主链使用 `ContentAddressedOtaStore`：完整 Manifest、App ID 作用域 CAS、current/previous、
  lease 和原子 State；HarmonyOS 不加入 candidate。

## 3. Runtime 与 XElement

- Android：`LynxRuntimeInitializer` 注册 Image、Log、HTTP 等 Service；`XElementRuntime` 把 4.0 全量 Behavior 装入每个 Builder。
- iOS：`LynxNativeRuntime` 配置全局 Runtime；XElement `Behavior` subspec 使用 AutoRegistry，`-ObjC` 防止静态链接裁剪。
- HarmonyOS：先注册 Log、DevTool、HTTP、Image Service，再执行 `LynxEnv.initialize`；Markdown 进程级初始化，SVG/WebView 通过 `BehaviorRegistryMap` 注入每个 `LynxView`，其余六类由核心 Registry 提供。

## 4. 资源层

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
| Sparkling Runtime | 不进入默认 Lynx 4.0 主链路；NativeModules 由宿主手工实现 |
| Explorer 展示能力 | 不包含扫码、Recorder、测试列表、Showcase、GN 构建任务 |

Harmony Explorer 位于 Lynx monorepo 内，官方工程依赖本地源码 override、GN/CMake 与 Bundle 构建。业务壳改为标准 OHPM 依赖，只保留应用宿主必需部分。

## 7. 扩展原则

1. 页面不直接依赖 Activity、UIViewController、UIAbility 或底层 Bridge 实例。
2. 新增原生能力先更新 [BRIDGE_CONTRACT.md](BRIDGE_CONTRACT.md)，再实现三端并更新 TypeScript。
3. 权限、登录、支付等能力不得返回假成功。
4. Bundle 签名、缓存、灰度、回滚和 CDN 属于发行系统，应在 Provider 上层完成。
5. 多页面共享状态交给原生 Store / Native Module，不依赖单个 `LynxView`。
6. 外部深链不得直接决定账户、支付或权限状态。
