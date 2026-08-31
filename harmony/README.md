# Lynx 4.0 HarmonyOS 原生壳（XElement 全量版）

这是一套面向业务 App 的 **HarmonyOS Stage 模型 Lynx 宿主壳**，采用 ArkTS + ArkUI。代码参考 Lynx `release/4.0/explorer/harmony` 的真实初始化、`LynxView`、Provider、Native Module 与 XElement 接入方式，但没有照搬 Explorer 的扫描、Recorder、测试页面、GN 构建和 Lynx monorepo 相对路径。

## 版本边界

| 项目 | 版本 |
|---|---:|
| Lynx 前端/PrimJS 主版本 | `4.0.0` |
| HarmonyOS `@lynx/*` OHPM 包 | `4.0.0` |
| HarmonyOS SDK | `5.0.1(13)` |
| DevEco Studio | 建议 `5.0.13.200+` |
| ImageKnifePro | `1.0.9` |

当前工程按 `parameter.json` 使用 HarmonyOS `@lynx/*` `4.0.0` 与 PrimJS `4.0.0`，静态检查器与运行时依赖口径一致。

## 工程结构

```text
harmony/
├── AppScope/                         # App 级名称、图标与版本
├── hvigor/                           # Hvigor 5 配置
├── build-profile.json5               # HAR Module + entry Demo、HarmonyOS SDK 13
├── oh-package.json5                  # @lynx/primjs 4.0.0
├── parameter.json                    # @lynx/* = 4.0.0
├── examples/                         # LynxShellModule TypeScript 声明
├── integration/sparkling/            # Sparkling Harmony 边界说明（不参与构建）
├── scripts/
│   ├── check_harmony_shell.py        # 静态验收
│   └── sync_bundle.sh                # 同步全部业务 Bundle 与 static
└── lynx_shell/
    ├── oh-package.json5              # Demo 显式依赖 @lynx/lynx-shell-kit
    └── src/main/
        ├── ets/
        │   ├── entryability/         # AbilityStage / UIAbility
        │   ├── common/               # Runtime / XElement / 安全 / 窗口
        │   ├── model/                # LynxPageRequest
        │   ├── routing/              # Explorer/Sparkling/壳协议
        │   ├── provider/             # Template/Generic/Media Fetcher
        │   ├── client/               # LynxView 生命周期回调
        │   ├── module/               # LynxShellModule
        │   └── pages/                # ArkUI 首页与单页 Lynx 容器
        └── resources/rawfile/bundles/
└── lynx_shell_kit/                   # 可复用 HAR Module
    ├── oh-package.json5
    └── src/main/ets/                  # Runtime / Provider / Bridge / LynxContainer
```

## XElement 全量范围

HarmonyOS `release/4.0` 官方源码包含 9 类 XElement：

1. BlurView
2. Input / TextArea
3. Overlay
4. Refresh
5. ScrollCoordinator
6. ViewPager
7. Markdown
8. SVG
9. WebView

其中前 6 类由 `@lynx/lynx` 的原生 Registry 注册；Markdown 通过 `XElementMarkdown.initialize()` 注册；SVG 与 WebView 通过 `BehaviorRegistryMap` 注入每个 `LynxView`。详见 [XELEMENT_INTEGRATION.md](XELEMENT_INTEGRATION.md)。

## 导入方式

1. 使用 DevEco Studio 打开本 `harmony/` 目录。
2. 同步业务 Bundle：

```bash
./scripts/sync_bundle.sh /absolute/path/to/playground/dist
```

目录模式会将其中全部 `*.lynx.bundle` 和 `static/` 同步到 rawfile；单文件路径仍可用。

构建并安装 Demo：

```bash
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleApp --no-daemon
hdc install -r build/outputs/default/harmony-default-unsigned.app
```

在 DevEco Studio 中配置签名后可生成发布包；当前已执行 HAR/HAP 构建，并在
`127.0.0.1:5555` HarmonyOS 模拟器验证本地 Bundle 渲染。

## 本地 Bundle

默认逻辑地址：

```text
assets://bundles/main.lynx.bundle
```

实际 HarmonyOS rawfile（当前 16 个 Bundle）：

```text
lynx_shell/src/main/resources/rawfile/bundles/main.lynx.bundle
```

rawfile 内置 Bundle 是发布资产，首次命中时直接读取并校验为 `ArrayBuffer`，不会复制到
`filesDir/lynx-ota-store`。远程 OTA 才会写入下面的 Store v3 CAS。

## 路由示例

```text
lynxshell://open?bundle=main.lynx.bundle&title=订单详情
lynx://open?url=local%3A%2F%2Fbundles%2Fmain.lynx.bundle
hybrid://lynxview_page?bundle=main.lynx.bundle&hide_nav_bar=1
file://lynx?local://main.lynx.bundle?fullscreen=true&orientation=portrait
```

远程地址不限制 Host，但必须使用 HTTPS；作为 `url` 参数传入时需要 URL 编码：

```text
lynxshell://open?url=https%3A%2F%2Fcdn.example.com%2Flynx%2Fmain.lynx.bundle
```

## HAR Module 与 Native Module

`lynx_shell_kit` 是可被其他 HarmonyOS Entry/HAP 复用的 HAR，公开入口为
`@lynx/lynx-shell-kit`。Demo 的页面入口、路由和 Runtime 初始化已经从该包引入；
`lynx_shell` 只保留 Ability、首页和 `@Entry` 包装，不再复制 Lynx 容器实现。

业务方只需要在 Entry 的 `oh-package.json5` 中声明这一项：

```json5
{
  "dependencies": {
    "@lynx/lynx-shell-kit": "file:../lynx_shell_kit"
  }
}
```

Lynx、PrimJS、Service、XElement、Provider、Router、Bridge 和 OTA 都由 HAR 的传递依赖
与公开入口提供，业务方不需要再逐项声明 `@lynx/lynx` 或各个 `@lynx/xelement_*` 包。

HAR 单独构建：

```bash
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleHar --mode module -p module=lynx_shell_kit@default --no-daemon
```

产物：`lynx_shell_kit/build/default/outputs/default/lynx_shell_kit.har`。

Lynx 页面默认不叠加 Harmony 原生标题栏；返回、标题和页面导航由 Bundle 自己绘制。
兼容字段仍保留，但当前 Container 不渲染原生 Toolbar。

### 路由转场动画

三端 `open`/`push` 使用统一的 `animated` 选项，默认值为 `true`，不传时沿用平台系统转场：

```ts
await LynxRouter.open(
  'detail.lynx.bundle',
  { orderId: '10001' },
  { animated: false }
);
```

`animated: false` 适合首屏重定向、连续跳转和自动化测试，会关闭本次打开/替换目标页面的
ArkUI Page 转场；`animated: true` 或省略时不覆盖系统默认动画。由于 HarmonyOS 当前使用
`@ohos.router`，该参数通过 `LynxPageRequest` 传给 `LynxContainer.pageTransition()`，而不是
直接传给 `router.pushUrl()`（该 API 没有逐次动画参数）。`clearTop` / `singleTask` 回到
已有页面时仍由系统 Router 控制回退动画。

### 键盘布局策略

HarmonyOS Router 与 Android 使用同一个页面参数 `keyboardBehavior`，默认值为 `system`：

```ts
await LynxRouter.open(
  'login.lynx.bundle',
  {},
  { keyboardBehavior: 'resize' }
);
```

支持 `system`、`resize`、`pan`、`nothing`。HarmonyOS 由 `UIContext.setKeyboardAvoidMode()`
映射到 ArkUI 的 `OFFSET`、`RESIZE`、`NONE`；不手工改写 LynxView 高度，也不要求业务页面自行监听
键盘避让区。该配置控制布局避让，不代表在没有输入焦点时强制弹出软键盘。

当前工程 `compatibleSdkVersion` 为 API 13；API 13 设备使用 `nothing` 时会安全降级为系统
`OFFSET`，API 14 及以上才启用 ArkUI 的真正 `NONE`（完全不调整布局）。

### Native Page Stack 与统一 Router

HarmonyOS 默认使用 `ArkUI Router + LynxContainer Page`；`NavPathStack` 保留为适配层替换点。业务只在 Ability
初始化时调用一次：

```ts
import { LynxRouter } from '@lynx/lynx-shell-kit';

LynxRouter.install(this.context);
await LynxRouter.open('pay.lynx.bundle', { orderId: '10001' });
await LynxRouter.open('https://cdn.example.com/pay.lynx.bundle', { orderId: '10001' });
LynxRouter.pop();
```

启用 Router 内置 OTA 时由宿主注入配置和客户端令牌：

```ts
const ota = new LynxOtaConfig('https://ota.example.com');
ota.environment = 'PROD';
ota.hostApp = 'capp';
ota.platform = 'harmony';
ota.clientToken = secureRuntimeToken;
LynxRouter.install(this.context, ota);

await LynxRouter.openOta('10000001', 'home.lynx.bundle', { orderId: '10001' });
await LynxRouter.deleteOtaBundles('10000001');
await LynxRouter.deleteAllOtaBundles();
```

Demo 验收不把令牌写进源码：可以通过 `EntryAbility` 的 `Want` 参数临时注入，示例命令如下
（把占位符替换成你自己的测试令牌；生产环境应改为安全配置或密钥服务）：

```bash
hdc shell aa start -a EntryAbility -b com.example.lynxshell \
  --ps lynx_ota_client_token '<runtime-token>'
```

该参数只用于启动时建立本次进程的 OTA 配置，不会写入仓库、HAR 或日志。

如果当前服务端还只接受 `android/ios`，可以只在过渡期设置请求平台，不改变 HarmonyOS 宿主身份：

```ts
ota.platform = 'harmony';
ota.serverPlatform = 'android'; // 临时复用 Android release；后端支持 harmony 后删除这一行
```

`platform` 用于宿主的 AppInfo/GlobalProps；`serverPlatform` 只用于
`latest-bundle-list` 查询、Release Manifest 和本地 state 校验。后端开放 `harmony` 后清空
`serverPlatform` 即恢复三端正式契约，不能长期把 Harmony 发布物伪装成 Android 发布物。

OTA 与直连边界：

- `openOta(appId, bundleName, params)`：Manifest/latest-list、app-scoped staging、size/SHA、
  `apps/<appId>/state.json` 的 `current/previous` Release ref、repair/rollback；新 state 不写
  Bundle 绝对路径。
- `open('https://...lynx.bundle', params)`：直接下载渲染，不进入 OTA、不过 30 分钟门控。
- 当前 Bundle 下载会在 `ArrayBuffer` 返回后执行 20 MB 硬上限；这是 Harmony Lynx 4.0
  Provider 接缝的临时内存边界，尚未等价于 Android 的流式落盘上限，需待目标 SDK 提供文件流
  API 后再收敛。

### 与 Android 最终 OTA 策略对齐

- Ability 启动/回前台：调用一次全量 `latest-bundle-list`，后台更新所有服务端返回的 App ID；
  不把这次全量请求放进 Tab 切换。
- 普通页面：先 `resolveCurrent` 读取已校验的 current 或 rawfile baseline；命中 remote current
  后通过 App ID 级 30 分钟门控后台检查，首屏不等待网络。
- 原生 Tab：只读 `resolveCurrent`，没有 active Bundle 就显示可重试错误，不 repair、不发网络请求；
  用户主动刷新或下一次冷启动再消费已提交的新 current。
- 普通 Page/Native Tab 首次读取时按 `sessionID + App ID` 建立进程内 NavigationSnapshot，固定
  `releaseId + manifestId`；同一 session 的后续页面按固定 Release 读取，不会随 current 漂移。
  主动刷新成功后先 reset Tab Snapshot，再由新 Tab generation 建立新 Snapshot；页面 lease 与
  Snapshot lease 分开释放。
- `ContentAddressedOtaStore` 的 Bundle SHA 校验结果只保存在进程内有界 Map，Key 包含 App ID、
  release、bundlePath、期望 SHA、文件大小、mtime、ctime 和 inode；不缓存 bytes、不落盘，
  Release/文件指纹变化自动失效。
- 首屏失败时先尝试 previous；没有 previous 但 Manifest 存在 rawfile baseline 时删除坏的
  downloaded current，下一次 `prepare` 直接读 rawfile，不复制 baseline 到应用私有目录。

### HarmonyOS Store v3（不含候选版本）

HarmonyOS 与 Android/iOS 使用同一份远程存储契约，但本端只保留稳定的 `current/previous`，不引入
候选版本状态：

```text
<context.filesDir>/lynx-ota-store/
└── apps/<lynxAppId>/
    ├── state.json                         # schemaVersion=3，current/previous
    ├── manifests/<manifestId>.json        # 完整 Manifest 快照
    ├── objects/<sha 前两位>/<sha>.lynx.bundle # App ID 作用域 CAS
    └── transactions/<transactionId>/*.part # 下载中间态
```

- 服务端仍下发完整 Manifest；相同 SHA 在同一个 App ID 下复用，V1 100 个 Bundle → V2 只变
  一个 Bundle 时只下载和写入一个新 CAS 对象，不复制另外 99 个。
- 相同 `releaseId` 或相同 SHA 在不同 App ID 下也分别受目录作用域保护，删除一个 App ID 不会影响另一个。
- 连续 V1…V10 后只保留 current/previous 的 Manifest 和仍被 Page/Tab lease 引用的对象；释放最后一个
  lease 后执行 Mark-and-Sweep 回收。
- 冷启动会清理可确认无引用的 orphan/transactions；损坏的 `state.json` 保守跳过。
- 删除全部 OTA 时只写一个短暂的 `.purge` 控制标记，不复制或备份 Bundle；有活体 lease 时先保护对象，
  最后一个 lease 释放或新进程启动后再完成清理并移除标记。
- 下载前先 prune，再用 Harmony 官方 `statfs.getFreeSizeSync` 做容量预检；空间不足不提交新 current。
- 不创建 `candidate.json`，也不改变 `current/previous` 的回滚语义。

`ContentAddressedOtaStore` 的校验缓存只保存 Bundle 指纹，不缓存 bytes；指纹包含 App ID、Object、
Bundle 路径、期望 SHA、文件大小、mtime、ctime 和 inode。

Launcher 和原生 ArkUI Tabs 顶部的“磁盘”入口会推入只读 Inspector Page。Inspector 展示 Store
真实 root、App ID、current/previous、leased/orphan 角色、Manifest ID、CAS 对象、文件树、transactions、
文件数和字节数；
刷新不请求 OTA、不计算 SHA、不修改文件，并且从 Tab 进入时不会销毁下层 Tab 的 lease。

### Demo 与 Android/iOS 的可见行为契约

Harmony Sample 只使用平台原生 ArkUI 承载，行为与 Android/iOS 当前验收 Demo 对齐：

```text
冷启动（没有外部 deep link）
  -> Manifest 精确解析 10000001/home.lynx.bundle
  -> 统一 OTA current / embedded baseline 选择链路

Playground 首页
  -> Manifest 精确解析 10000001/main.lynx.bundle

ArkUI Tabs Home / Settings
  -> 同一个 10000001/main.lynx.bundle
  -> 只调用 resolveCurrent
  -> source 保留 ota_current / embedded_baseline
  -> loadPolicy 单独标记 cache_only

用户点击“刷新 OTA”
  -> 等待全量 latest-bundle-list 和原子提交完成
  -> 成功才递增 refreshGeneration，重建两个 LynxView
  -> 失败保留当前 Tab 实例和版本
```

Tab 普通切换不会递增 `refreshGeneration`，因此保留 LynxView、滚动和页面状态，也不会触发网络。
Manifest 身份缺失时直接显示错误，不静默降级成 `assets://` 直读。

当前 checkout 已执行 `ohpm install`、`assembleHar` 和 `assembleApp`，HAR 与完整 App 均构建成功；
`python3 scripts/check_harmony_shell.py --quiet` 为 `87 PASS / 0 WARN / 0 FAIL`。本轮使用
Pura 90（HarmonyOS 6.1.1(24)，HDC `127.0.0.1:5557`）重新安装 unsigned App，并通过本地
OTA Server 的真实 HTTP 请求验证 Store v3；本地服务只用于 TEST，生产仍要求 HTTPS。

模拟器运行态已证明：

- 干净安装 V1：latest=1，下载 100 个 Bundle，共 8,775,400 bytes；
- V2 冷启动：只下载 `pages/10000001/bundle-050.lynx.bundle` 1 次，共 87,754 bytes；下一次冷启动
  页面显示 V2-050，未复制另外 99 个对象；
- 原生 ArkUI Tabs 普通切换：latest=0、Bundle=0；主动刷新回 V1 后页面重建并显示 V1-050，
  Bundle=0；重复刷新命中服务端 ETag，HTTP 304；
- 坏 SHA：同步失败时保留 V1，Inspector 仍显示 current=V1、previous=V2，CAS=101，未提交坏对象；
- 只读 Inspector：真实 root 为 `files/lynx-ota-store`，可见 1 个 App、101 个 CAS Object、2 份
  完整 Manifest 和 current/previous lease；没有 candidate/trial；
- 内置 rawfile 只作为 baseline 直接读取，不复制到 OTA Store。
- `scripts/ota-store-v3/run-harmony-fault-tests.sh` 已覆盖 7 个事务边界、容量为 0 和服务断连；
  `run-harmony-process-crash-tests.sh` 已在 5 个边界用 HDC force-stop 后冷启动恢复，提交前 current=V1，
  提交后 current=V2，恢复均不重复下载 050。

完整步骤、请求计数、截图和未覆盖边界见独立报告：
[harmony-ota-store-v3-test-report.html](../docs/harmony-ota-store-v3-test-report.html)。旧的
`harmony-ota-test-report.html` 与 `VALIDATION.md`/`VALIDATION_REPORT.txt` 仍是 Store v2 历史基线，
不代表当前 v3 结果。

它与 Android `LynxRouter.open(context, bundle, params)`、iOS
`LynxRouter.open(bundle:params:)` 对齐；不需要预注册 routeId，也不引入 Fragment。

### Native Module

模块名：`LynxShellModule`

```text
open
close
back
popTo
popToWithOptions
closeAll
closeAllWithOptions
reLaunch
redirect
getNavigationState
closeWithResult
consumeNavigationResult
prepareRoute
cancelPreparedRoute
markTransitionReady
getTransitionState
setStorageItem
getStorageItem
removeStorageItem
clearStorage
getAppInfo
emitToNative
broadcast
sendToPage
chooseMedia
uploadFile
uploadImage
downloadFile
saveDataURL
```

持久化使用 HarmonyOS Preferences；导航使用 ArkUI Router，并在进程内维护
`sessionID/entryID/routeKey` 栈元数据。普通 Module 方法按 Lynx Harmony 异步语义执行，因此结果通过
callback 返回。媒体/文件五项目前保留同名方法并返回稳定 `code=1004`，避免页面收到
`is not a function`；真正接入系统 Picker、上传下载前不能把它们当成已完成能力。

## 静态检查

```bash
python3 scripts/check_harmony_shell.py
```

该脚本检查工程文件、JSON/JSON5、版本、OHPM 依赖、XElement 9/9、Runtime 顺序、Provider 安全边界与取消、Bridge 契约、固定路由入口、Sparkling 隔离、注释和分隔符。它是静态门禁，不等价于 DevEco 编译。
