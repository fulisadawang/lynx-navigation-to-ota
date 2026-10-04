# LynxCapacitorModule 三端 Demo 接入

默认 Android、iOS、HarmonyOS Demo 显式安装同名 `LynxCapacitorModule`。模块保持独立
AAR / Pod / HAR，Shell 只提供额外模块注册或生命周期入口，不把能力实现合并进 Router/OTA。
页面可继续使用已有 `@cclx/lynx-native-bridge/capacitor`；四个 transport 和 40 域/146 方法目录不变。

## Android

- Gradle graph 添加 `:lynx-capacitor`，仅 Sample 显式依赖它。Sample 使用 compileSdk 36、
  minSdk 26、Java/Kotlin 17；Shell 核心也对齐 minSdk 26、Java/Kotlin 17，构建 JDK 为 21。
- `LynxCapacitorDemoHost.install` 在 Router Runtime 初始化后、首个页面加载前安装能力 Runtime，
  使用 SDK `LynxEnv.registerModule` 注册。Library Manifest 合并权限、FileProvider 和能力 Activity。
  正式宿主必须在 Application.onCreate、首个 Activity 创建前执行安装；App.getState 由实际
  resumed 生命周期快照读取，不能把尚未销毁的后台 Activity 当作 App active。
- Shell Page 与 Tab 在实际显示时转发当前 LynxView，恢复对应 Activity 与 Module 事件出口；
  请求使用调用 Module 的 Context，不借用后来打开的页面。Tab 的 Motion listener 按事件出口隔离。
- 普通 Page 和 Native Tab Activity 转发权限、拍照/扫码结果；新 Intent 只转发通知动作，
  不覆盖 Shell Intent 保存的路由与返回策略。能力 Runtime 复用 Application 生命周期释放资源。
- 公开 `LynxCapacitorHostProvider` 由 Sample composition root 安装，通过 Shell 中性
  System UI handle 操作调用 View 的系统栏、方向和文字缩放。状态目录仍不代表权限已授予。
  当前 Android SDK 的真实 Module 销毁链会转发 `destroy()`。媒体统一后，Shell 的全部
  View 销毁出口还会先调用媒体 host 的 exact-context hook，确保 Shell 先调用、Cap Module
  尚未惰性创建时的 owner 也能取消；两条出口都进入幂等 `destroyForContext`。

- 默认 Sample 同时调用 `LynxShell.installNativeMediaHost`：`call` 转交 Cap Runtime 的
  `handleLegacyMedia`，`onViewDestroy` 转交 `destroyForContext`。正式宿主必须在首个 View 前
  安装此中性 SPI；旧五媒体方法保留 ABI，缺接线返回真实 `code=-1`，不退回旧无界实现。

## iOS

- 新增独立 `LynxCapacitorKit.podspec`；普通 Demo 和 Core E2E Host 均通过 Podfile 依赖。
  六项基座阶段已通过实际 pod install 与 E2E Host 构建接入，依赖版本保持锁定；
  最终媒体源码已重新构建并在 iOS18.1 Core E2E Host 显示 Demo；普通带地图宿主的全能力未验收。
- AppDelegate 在 bootstrap 前调用 `LynxRouter.registerNativeModule`，额外模块应用到全局和
  每个 View 的独立 Config，因此普通 Page 与 Native Tab 都经过同一注册链路。
- 注册同时提供 `onViewDestroy: LynxCapacitorModule.destroy(for:)`。当前 SDK 不自动调用
  普通 Module.destroy，Shell 在真正释放 View 前按 Context 执行一次宿主释放回调。
- 两份 App Info.plist 补充当前 adapter 读取的相机、麦克风、相册、联系人、日历、位置与
  Face ID 用途文案。Scene 转发冷启动 URL 和后续外链，AppDelegate 转发真实 APNs 成败/消息。
  前后台观察沿用能力 Runtime 已有实现，避免重复投递。
- Sample 通过公开 Host provider 把方向、状态栏、系统栏与当前输入框样式映射到 Shell
  中性系统 UI handle。异步方向以实际 Scene 结果为准；系统管理或没有当前输入框的方法
  仍返回明确不可用/partial，自绘导航和容器实测安全区域继续沿用。

- AppDelegate 在 bootstrap 前通过 `LynxRouter.installMediaHandler` 连接
  `LynxCapacitorModule.handleLegacyMedia(for:method:optionsJSON:callback:)`。同 Context 的旧
  Shell 媒体与惰性 Cap Module 共用 Runtime；原 destroy hook 也释放没有 Module 实例的
  共享媒体 owner。

## HarmonyOS

- 根 build profile 添加能力 HAR，Entry 显式依赖能力包；Shell HAR 不直接依赖它。
- Ability 在创建页面前注入 `UIAbilityContext` 并安装注册表，普通 Page 和 Native Tab 均应用。
  Context 真正移除/替换时调用 `destroyForContext`，页面被覆盖但保留时不提前销毁。
- 初始/后续 Want URL、App 前后台与 Ability 销毁使用既有模块入口；Page 返回监听仅交给当前
  Context，后台页面不会消费当前页返回。
- Entry 声明源码实际使用的相机、麦克风、粗定位、联系人、日历、震动、提醒和网络权限，
  权限用途资源随 Sample 提供。厂商 push/后台任务等外部能力未自动配置。

## 验证与发布边界

上一轮的 `verification.host=configured_not_run` 仅表示源码已装配。本轮 iOS 已执行 Core、
Host、UI 和资源检查；Android 已完成本地 Debug/Release 构建、JVM、API 26/36 宿主回归，
iOS Host/UI 按测试方法合并最新结果为 67 PASS、1 SKIP；Android API26/API36 各
23 个有效宿主测试方法 PASS，历史批次与补跑分别列于报告。
两端不能互相代替验证，全部能力和硬件也未因部分用例通过而完成验收。
既有 partial/unsupported、缺少平台 owner/provider、APNs entitlement 等结果继续保留真实错误。

上一轮只做源码装配。本轮用户已授权按用例先验证 iOS、生成报告后再实施 Android；Harmony
暂缓。具体结果以 `docs/native-readiness-v1/ios-test-report.html` 和
`docs/native-readiness-v1/android-test-report.html` 的每项证据为准。
真机硬件、生产监控和正式业务 App 验收不以本地测试代替。本轮Git交付由用户随后明确授权；软件报告仍为各阶段冻结证据。
新 Bundle 使用已有 App 版本兼容范围发布，不新增独立协议版本门禁。


## 当前原生媒体统一的验证边界

图片/视频选择、原生视频预览与App内图片列表预览已写入双端源码，并保留旧 Shell 五方法。
每次多选最多16项；真实拍摄权限、codec、多图手势、取消/多View等需对应平台验收。
最终媒体源码已重新构建、安装并显示入口及 iOS 来源菜单；新增媒体完整用例未执行，上面的六项报告是媒体修改前的历史证据，不能
自动解释为新媒体链已运行通过。接线/负载/平台差异与验收规格见 docs/native-media-v1/。

Android宿主接线阶段已把AGP由8.5.2调整到8.9.1以配合compileSdk36，实际构建使用Gradle8.11.1/JDK21；Cap的JVM字节码target由21对齐默认Shell/App的17。Lynx/PrimJS及既有相机等SDK版本保持原锁定值。
