# AGENTS.md — HarmonyOS `lynx_shell_kit`

> 本文件面向 AI 编程代理，对 `harmony/lynx_shell_kit/` 及其子目录生效。与仓库根规则冲突时遵守更高层级规则；本文件只补充 HarmonyOS HAR Module 的局部边界。

## 模块定位

`lynx_shell_kit` 是业务方唯一需要接入的 HarmonyOS HAR Module，负责：

- Lynx 4.0 Runtime、Service、XElement 和模块初始化；
- ArkUI `LynxContainer`、Router、原生 Page Stack 与页面状态；
- `LynxShellModule`、Storage、消息和宿主能力 Bridge；
- Bundle Provider、embedded rawfile Registry；
- OTA Store v3、完整 Manifest、App ID 作用域 CAS、State、lease、回滚和诊断。

`harmony/lynx_shell/` 是 Entry Demo，只依赖 HAR，不属于本目录。不要把 Demo 页面、按钮或测试配置放进 HAR 公共实现。

`harmony/lynx_capacitor_kit/` 是 sibling 原生能力 HAR 源码，当前尚未加入根 `build-profile.json5` 和 Entry Demo 依赖。它不属于 Shell/OTA；任务明确涉及该模块时先读 `harmony/lynx_capacitor_kit/AGENTS.md`，再显式处理 Module 注册、权限、UIAbilityContext 和生命周期转发。

## 开工前必须读取

按任务相关性读取：

1. 根目录 `PROJECT_MAP.md`、`ARCHITECTURE.md`。
2. `harmony/README.md`、`harmony/ARCHITECTURE.md`。
3. 本目录 `oh-package.json5`、`build-profile.json5`、`hvigorfile.ts`。
4. 接入/路由：`MODULE_INTEGRATION.md`、`ROUTER_CONTRACT_V1.md`、`ROUTING.md`、`NAVIGATION_README.md`。
5. Bridge：`BRIDGE_CONTRACT.md`。
6. OTA：最新 Store v3 测试用例、Harmony HTML 报告和 `scripts/ota-store-v3/`。
7. 静态门禁：`harmony/scripts/check_harmony_shell.py`。
8. 跨到原生能力层时：`harmony/lynx_capacitor_kit/AGENTS.md` 和 `LynxCapacitorCatalog.ets`。

文档、代码和运行结果冲突时，以当前 ArkTS/ArkUI 源码、OHPM/Hvigor 配置和最新 HDC 证据为准。

## 目录与职责

```text
src/main/ets/
├── common/        请求、配置、GlobalProps 和公共类型
├── module/        LynxShellModule Bridge
├── ota/           API Client、Store v3、Runtime、embedded Registry
├── pages/         LynxContainer、LynxTabContainer
├── provider/      Bundle/Template Provider
├── routing/       LynxRouter、LynxNavigator、路由解析和页面栈
└── runtime/       Lynx Runtime/Service/XElement 初始化
```

不要把 `harmony/lynx_shell/src/main/ets` 的 Entry Demo 实现复制进 HAR。需要演示时由 Demo 依赖公开 API。

## 不可破坏的架构约束

### 1. HAR 与依赖所有权

- 业务只依赖 `@lynx/lynx-shell-kit`；Lynx、Service、XElement 和 OTA 依赖由 HAR 管理。
- 不让 Demo 重复声明 HAR 已拥有的底层依赖。
- ArkTS 代码保持显式、可静态分析的类型；避免动态对象、隐式 any 和不受支持的 TS 语法。
- 不手改 `oh_modules/`、`.hvigor/`、build 输出或 OHPM lock 中的安装产物来替代源码修复。
- 未经明确授权不要升级 API level、Lynx/XElement 版本或依赖来源。

### 2. Router 与容器

- 默认是 ArkUI `LynxContainer` Page + `@ohos.router`；公开 `LynxRouter` 不暴露底层 Router 细节。
- NavPathStack 若以后接入，只替换平台适配层，不改变 Bundle、params、session、生命周期和 Bridge 契约。
- `animated=false` 由目标 Page 的 `pageTransition()` 使用零时长 enter/exit；不要假设 `router.pushUrl()` 支持逐次动画参数。
- HarmonyOS 当前没有 Android/iOS 同级的原生共享元素/Open Container 协调器。`getTransitionState` 必须明确返回 Router 降级态，禁止伪造完成。
- Direct Bundle 与 OTA Bundle 身份严格分离；禁止用 URL 猜 App ID 或把手机路径传入 Router。
- Page、Native Tabs 和普通 open 使用同一 session/entry/routeKey/结果语义。
- Native Tabs 只是容器能力；HAR 不拥有业务 TabBar 设计或导航配置。

### 3. OTA Store v3

固定逻辑布局：

```text
<context.filesDir>/lynx-ota-store/apps/<lynxAppId>/
├── state.json
├── embedded.json
├── manifests/<manifestId>.json
├── objects/<sha前两位>/<sha>.lynx.bundle
└── transactions/<transactionId>/
```

- HarmonyOS 不实现 candidate/trial，只保留 `current/previous + active lease + transaction roots`。
- App ID 物理隔离；相同 SHA 不跨 App ID 共享对象。
- Manifest 是完整快照；V2 只变化一个 Bundle 时只下载/写入一个缺失对象，不复制另外 99 个。
- embedded Bundle 直接读取 HAP rawfile；`embedded.json` 只描述身份，不复制 bytes 到 OTA Store。
- Object 校验后原子发布，Manifest durable 后最后提交 State；State 是唯一激活点。
- 对文件和父目录的 `fsync`、rename、transaction recovery、`.part` 清理和 prune roots 是耐久性契约，不能为了简化删除。
- 有效 `transaction.json` 在恢复前保护已经发布的 CAS Object；成功提交后才清理事务目录。
- 启动/前台全量同步、页面 30 分钟后台检查、缺包修复和首屏回滚语义与另外两端一致。
- `serverPlatform=android` 只允许作为当前 Demo/测试服务兼容值；宿主身份、AppInfo 和 Router platform 仍是 HarmonyOS。

### 4. Page/Tab lease 与生命周期

- Page/Tab 读取 downloaded Bundle 时必须持有 lease；销毁、刷新、错误和过期异步结果都要释放。
- NavigationSnapshot lease 与页面 lease 分开管理；同一 session 不得在 current 切换后漂移到新 Manifest。
- Tab 普通切换只读 current，不联网；主动刷新成功后先 reset Snapshot，再递增 generation 重建内容。
- delete 只清远程 OTA 内容，不删除 HAP rawfile；活体 lease 保护对象直到最后一个消费者释放。
- 首屏失败最多回滚一次；第二次失败显示明确错误，不无限重试。

### 5. Bridge 与平台能力

- `LynxShellModule` 方法名、参数、结果码与三端 `BRIDGE_CONTRACT.md` 一致。
- UI/Router 操作进入正确的 ArkUI/UIContext；网络和磁盘不能阻塞 UI。
- 不支持的 Picker、上传下载或原生转场能力返回稳定 `1004`/降级原因，禁止假成功。
- 原始 Module 成功码是 `code=0`；页面 wrapper 归一化规则不在 HAR 内重复实现。
- 不在 main-thread 高频动画函数里调用 NativeModules、网络或 Router。
- GlobalProps 的宿主保留字段不能被业务 params 覆盖。

### 6. `BuildProfile.ets` 特别规则

- `BuildProfile.ets` 可能包含本机/宿主构建适配，视为用户工作区文件。
- 除非任务明确点名，不修改、格式化、覆盖或暂存该文件。
- 如果它与当前构建冲突，先报告差异和影响，不自行回滚。

## 安全与工作树

- 不把 token、Cookie、签名 URL、请求头、证书、私钥和签名配置写入源码、测试、日志或文档。
- 不提交 `.app`、HAP/HAR 构建产物、oh_modules、Hvigor cache、模拟器数据和生成 Fixture 二进制。
- 本地 HTTP 和 fault/pause/capacity 注入只允许在 TEST/显式调试配置下启用。
- 保留用户已有修改，尤其是 `BuildProfile.ets`；禁止 reset/checkout 覆盖。
- 不修改 `harmony/lynx_shell`，除非任务明确要求 Demo UI 或 HDC 运行态验收。
- 不隐式依赖或注册 `harmony/lynx_capacitor_kit`；默认 build profile/Entry 尚未包含它。

## 修改后的最低验证

```bash
# HarmonyOS 静态门禁
python3 harmony/scripts/check_harmony_shell.py --quiet

# HAR 构建
cd harmony
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleHar --mode module -p module=lynx_shell_kit@default --no-daemon

# 完整 Demo App 构建（仅任务涉及 Entry/运行态时）
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleApp --no-daemon
```

涉及 OTA、Router、Page、Tabs、delete、恢复、文件原子性或错误态时，还需在 DevEco emulator/真机用 HDC 验证。优先复用：

```text
scripts/ota-store-v3/run-harmony-fault-tests.sh
scripts/ota-store-v3/run-harmony-process-crash-tests.sh
scripts/ota-store-v3/assert-harmony-results.mjs
docs/harmony-ota-store-v3-test-report.html
```

受控 capacity/ENOSPC、HDC force-stop、模拟器和本地 Server 证据不能冒充真实断电、真实 OS ENOSPC、签名包或生产 CDN/TLS。

## 交付说明

最终回复必须说明：

- 改动是否只在 HAR，是否影响 Entry Demo；
- 是否改变 Router、Bridge、OTA、Store schema 或平台降级语义；
- 执行了哪些静态、Hvigor、HDC 和故障验证；
- 哪些物理真机、签名、断电和生产环境边界未覆盖；
- 是否触碰或保留了 `BuildProfile.ets`。
