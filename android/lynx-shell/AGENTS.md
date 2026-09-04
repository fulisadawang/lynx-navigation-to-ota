# AGENTS.md — Android `lynx-shell`

> 本文件面向 AI 编程代理，对 `android/lynx-shell/` 及其子目录生效。与仓库根规则冲突时，优先遵守更高层级规则；本文件只补充 Android Library Module 的局部边界。

## 模块定位

`lynx-shell` 是业务方可复用的 Android Library/AAR，不是 Sample App。它同时拥有：

- Lynx 4.0 Runtime、Service 和 XElement 注册；
- Activity-first Router、Container、原生页面栈与恢复；
- `NativeModules.LynxShellModule`、存储、消息和媒体 Bridge；
- Android 原生转场、共享元素、Open Container、Sheet 和 Back 手势；
- 内置 OTA Store v3、Manifest、CAS、State、lease、回滚和诊断。

`android/app/` 是验收 Sample，不属于本目录。不要为了修改 Library 而把 Sample 代码复制进 Module，也不要把 Module 实现下沉到 Sample。

`android/lynx-capacitor/` 是 sibling 原生能力 Module，当前尚未加入默认 `settings.gradle.kts` 和 Sample。它不属于 `lynx-shell`，不得把能力实现直接塞进 Router、Container 或 `LynxShellModule`；任务明确涉及该模块时先读 `android/lynx-capacitor/AGENTS.md` 并单独完成构建图、注册、权限与生命周期接线。

## 开工前必须读取

按任务相关性读取，不要凭经验猜协议：

1. 仓库根 `PROJECT_MAP.md`、`ARCHITECTURE.md`。
2. 接入/路由：`MODULE_INTEGRATION.md`、`ROUTER_CONTRACT_V1.md`、`ROUTING.md`、`NAVIGATION_README.md`。
3. Bridge：`BRIDGE_CONTRACT.md`。
4. 转场：`TRANSITIONS_README.md`。
5. OTA：本目录 `OTA_RUNTIME.md` 和根目录 OTA 测试报告。
6. 依赖：本目录 `build.gradle.kts`、`consumer-rules.pro`、根目录 `XELEMENT_INTEGRATION.md`。
7. 跨到原生能力层时：`android/lynx-capacitor/AGENTS.md` 和它的 `NativeCapabilityCatalog.kt`。

文档、代码和运行结果冲突时，以当前代码、构建配置和最新运行证据为准，并修正文档。

## 目录与职责

```text
src/main/java/com/example/lynxshell/
├── LynxRouter.kt                  对外 Router + OTA 门面
├── container/                     Activity-first 容器与 Builder
├── routing/                       原生页面栈、参数、恢复
├── transition/                    自定义转场、快照、手势状态机
├── bridge/                        LynxShellModule、Storage、消息、媒体
├── runtime/                       Lynx 4.0、Service、XElement
├── provider/                      本地/HTTPS Bundle Provider
└── ota/                           Router 与 OTA Runtime 接线

src/main/kotlin/com/ota/android/sdk/
└── OTA 协议、HTTP、Store v3、CAS、Manifest、State、回滚
```

不要仅因为 Kotlin 文件位于 `src/main/java` 就机械移动目录；现有 source set 可正常编译，重排属于额外迁移任务。

## 不可破坏的架构约束

### 1. 页面和路由

- 默认是一页 Lynx 对应一个真实 `LynxShellActivity`。
- Fragment 只作为宿主承载能力，不替代 Router 的 Activity-first 公共契约；Module 不拥有业务 BottomNavigation。
- Router 只传逻辑身份和 JSON 参数，不把手机绝对路径写入 Intent、栈状态或 Bridge。
- Direct Bundle：`bundleUrl + params`；OTA Bundle：`lynxAppId + bundleName + params`。禁止互相猜测或隐式转换。
- `launchMode`、`back/popTo/closeAll/reLaunch/redirect`、页面结果和 session 语义必须与 `ROUTER_CONTRACT_V1.md` 一致。
- 默认不在通用容器强制显示业务骨架；本地有效 Bundle 立即打开，只有缺包/损坏修复链路才显示原生 Loading。

### 2. OTA Store v3

固定逻辑布局：

```text
files/lynx-ota-store/apps/<lynxAppId>/
├── state.json
├── embedded.json                  仅身份描述，不包含 Bundle bytes
├── manifests/<manifestId>.json    完整 Manifest 快照
├── objects/<sha前两位>/<sha>.lynx.bundle
└── transactions/<transactionId>/
```

- App ID 物理隔离；相同 SHA 不得跨 App ID 共享对象。
- Manifest 是完整快照，不设计长期 delta/patch 链。
- Bundle 先校验 size/SHA，再发布 Object 和 Manifest，最后原子提交 State；State 是唯一激活点。
- embedded Bundle 直接从 APK assets 读取并校验，不复制到私有 Store。
- `current/previous/candidate/active lease/transaction` 都是 GC roots；禁止只看文件时间或持久化 refcount 删除对象。
- 普通 Activity 可选 candidate；Native Tab 永远只读 current，不消费 candidate，不因切 Tab 联网。
- 页面打开的 30 分钟门控只控制后台版本检查；缺包、损坏、启动/前台全量同步不受该门控限制。
- 首屏失败最多回滚一次，禁止无限重试。
- Store v3 不迁移 v2 Demo 沙盒；需要验证新 schema 时卸载重装。

### 3. 原生转场

- 一次跳转只有一个动画所有者。显式 `transition/routeType` 或 `animated=false` 后，必须抑制 Activity Window 动画。
- `LynxTransitionCoordinator` 负责 push/pop、fallback、Predictive Back、低版本 edge 手势和最终栈提交。
- ReactLynx 只声明 selector/key/ready，不上传屏幕坐标，不逐帧驱动原生转场。
- 共享元素和 Open Container 的 selector、几何、快照和 progress 都在 Android UI 主线程处理。
- `heroSheet` 是透明全屏宿主；Lynx 页面控制入场、滚动、导航渐变和下拉关闭，原生不得抢纵向触摸流。
- fallback 必须留在壳内执行 `fade/slide/none`，不能重新落回系统 Window 动画。
- Reduce Motion、动画取消、Activity 重建和目标首屏失败必须有明确终态。

### 4. Bridge 与线程

- 所有 UI/Router 操作进入 Android 主线程；高频动画帧不跨 NativeModules Bridge。
- Android 对象型 callback 必须用 `Arguments.makeNativeMap` / `JavaOnlyMap` / `JavaOnlyArray` 编码。
- 禁止把 Kotlin `HashMap` 直接传给 `Callback.invoke`；真机会导致 callback 收到 `null`。
- 原始 NativeModule 成功码是 `code=0`；Playground wrapper 才归一化为 `code=1`。不要混用。
- 不支持的能力返回稳定错误码，不得伪造成功。
- 生命周期结束必须取消 Provider、销毁 LynxView、关闭 OTA lease，并清理动画/回调。

### 5. Lynx 与依赖

- Lynx、PrimJS、Service 和 10 个 XElement 依赖统一为 `4.0.0`，未经明确授权不要升级或混入 nightly。
- 每个 `LynxViewBuilder` 必须安装统一 XElement BehaviorBundle。
- 保留 `consumer-rules.pro` 中的反射入口。
- Library `minSdk=24`、`compileSdk=35`、Java/Kotlin 17；修改前先确认兼容范围。
- 不新增 Web DOM/BOM 心智，不假设 Lynx 支持 Android WebView API。

## 安全与工作树

- 不把 token、Cookie、签名 URL、请求头、私钥写入源码、测试、日志或文档。
- 本机 OTA 配置只能放入已忽略的 `ota.local.properties` 或环境变量。
- 不提交 APK、Gradle cache、构建目录和生成的 Fixture 二进制。
- 工作树可能包含用户改动；禁止 reset、checkout 或格式化无关文件。
- 不修改 `android/app/`，除非任务明确要求同步 Sample 或运行验收。
- 不隐式依赖或注册 `android/lynx-capacitor`；默认工程尚未把它加入 Gradle graph。

## 修改后的最低验证

按改动范围选择，不能把静态检查当作运行态：

```bash
# 仓库根静态门禁
python3 scripts/static_check_android_ios.py --quiet

# Android Library JVM 测试（仓库当前未提交 Wrapper，可使用本机 Gradle）
cd android
gradle :lynx-shell:testDebugUnitTest --no-daemon

# Sample 构建
gradle :app:assembleDebug --no-daemon
```

涉及 UI、转场、Back、Fragment、Activity 恢复或 OTA 页面时，还需在 emulator/device 验证，并记录：设备/API、Bundle 身份、网络请求数、页面版本、截图或日志。涉及 Store v3 时优先复用 `scripts/ota-store-v3/` 和 `docs/lynx-ota-store-v3-test-cases.md`。

## 交付说明

最终回复必须说明：

- 改了哪些文件和公共契约；
- 为什么属于 Module 而不是 Sample；
- 执行了哪些静态、单测、构建和设备验证；
- 哪些平台/设备未覆盖；
- 是否改变 OTA、Router、Bridge 或转场兼容性。
