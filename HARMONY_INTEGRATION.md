# HarmonyOS Lynx 4.0 壳接入说明

## 核心入口

```text
harmony/
├── AppScope/
├── build-profile.json5
├── oh-package.json5
├── parameter.json
├── hvigor/
├── scripts/
└── lynx_shell/
    ├── oh-package.json5
    └── src/main/
        ├── ets/
        │   ├── entryability/
        │   ├── common/
        │   ├── model/
        │   ├── routing/
        │   ├── provider/
        │   ├── client/
        │   ├── module/
        │   └── pages/
        └── resources/rawfile/bundles/
└── lynx_shell_kit/
    ├── oh-package.json5
    └── src/main/ets/                   # 可复用 HAR Module
```

## 初始化顺序

```text
LynxAbilityStage: ImageKnife 文件缓存
              ↓
EntryAbility: Log / DevTool / HTTP / Image Service
              ↓
LynxEnv.initialize
              ↓
LynxEnv.setAppInfo
              ↓
XElementMarkdown.initialize
```

顺序集中在 `LynxRuntimeInitializer.ets`，禁止页面各自重复初始化。

业务 App 推荐只调用一个公开入口：

```ts
import { LynxRouter } from '@lynx/lynx-shell-kit';

LynxRouter.install(this.context);
```

HarmonyOS 默认 Native Page Stack 为 `ArkUI Router/NavPathStack + LynxContainer Page`。
它与 Android Activity-first、iOS UINavigationController 页面栈共享同一套 Bundle、params、
页面身份、生命周期和消息协议，但不复制 Android 的 Activity/ViewStack 代码。

## 打开工程

1. 使用 DevEco Studio 打开 `harmony/` 目录；
2. 在 `harmony/lynx_shell/src/main/ets/common/ShellSecurityPolicy.ets` 中确认 HTTPS、Bundle 后缀、响应码和体积限制；当前不配置 Host 白名单；
3. 将业务 Bundle 同步到 rawfile；
4. 配置业务 Bundle Name、应用 Bundle Name 和签名；
5. 选择 `lynx_shell` Demo；Runtime、Provider、Bridge 和 LynxContainer 来自
   `lynx_shell_kit` HAR Module。

同步命令：

```bash
cd harmony
./scripts/sync_bundle.sh /absolute/path/to/playground/dist
```

目录模式会同步全部 `*.lynx.bundle` 与 `static/`；当前 Playground 共 16 个 Bundle。

构建：

```bash
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleApp --no-daemon
```

HAR 单独产物为 `lynx_shell_kit/build/default/outputs/default/lynx_shell_kit.har`。

## 需要业务方替换的配置

- `AppScope/app.json5`：App Bundle Name；
- `lynx_shell/src/main/module.json5`：Module/Ability 元数据；
- `ShellConstants.ets`：App 名称、版本、默认 Bundle；
- `ShellSecurityPolicy.ets`：模板与资源 HTTPS、Bundle 后缀、响应码和体积策略；当前不配置 Host 白名单；
- `lynx_shell_kit`：可复用的 Runtime / Container / Provider / Bridge Module；Demo 通过
  `@lynx/lynx-shell-kit` 引用，Lynx 页面默认不显示原生标题栏；
- 图标和文案资源；
- 签名配置。

## 原生打开 Lynx

```ts
import { LynxRouter } from '@lynx/lynx-shell-kit';

await LynxRouter.open('pay.lynx.bundle', { orderId: '10001' });
await LynxRouter.open('https://cdn.example.com/pay.lynx.bundle', { orderId: '10001' });
await LynxRouter.openScheme('hybrid://lynxview_page?bundle=detail.lynx.bundle&title=详情');

LynxRouter.pop();
LynxRouter.popTo('main.lynx.bundle');
LynxRouter.closeAll();
```

页面侧 NativeModules 还支持 `emitToNative`、`broadcast`、`sendToPage`；生命周期事件名
为 `lynxRouterLifecycle`。完整字段见 [ROUTER_CONTRACT_V1.md](ROUTER_CONTRACT_V1.md)。

## 当前没有包含的业务能力

- 登录态、Token 注入、支付、定位、相机、相册；
- Bundle 签名、版本清单、灰度、回滚、缓存淘汰；
- 公司业务自己的 Tab/主页选择逻辑（通过宿主 Home Handler 接入）；
- DevTool 的 Release 裁剪策略；
- 网络重定向逐跳验证；
- 业务监控、崩溃和性能上报。

这些能力应通过独立 Adapter/Provider 接入，不应修改 `LynxContainer` 的核心职责。
