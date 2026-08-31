# HarmonyOS Store v2 历史验收范围

> 本文件记录 2026-08-27 的 Store v2/Mock Source 基线，仅作历史留档，不代表当前 checkout 的
> Store v3 实现或运行结果。当前 v3 证据请查看 `docs/harmony-ota-store-v3-test-report.html`。

历史静态结果：`85 PASS / 0 WARN / 0 FAIL`；当时检查器已覆盖 Store v2、无候选版本、lease 和只读
Inspector 契约，依赖口径为 `parameter.json=4.0.0`。

## 已完成

- ArkTS/ArkUI 工程结构；
- OHPM 依赖和版本映射；
- Service → LynxEnv → XElement 初始化顺序；
- XElement 9/9 静态清单；
- Template/Generic/Media Provider；
- Explorer/Sparkling/自定义路由；
- Preferences Native Module；
- HarmonyOS `LynxShellModule` 的 26 个公开方法（基础存储/AppInfo、导航栈、准备/转场状态和
  5 个稳定 `1004` 媒体占位方法）；
- 模块清单、深链与 INTERNET 权限；
- `lynx_shell_kit` HAR Module 独立构建，并由 `lynx_shell` Demo 实际引用；
- Playground 16 个 Bundle 与 `static/` 已同步到 HarmonyOS rawfile；
- Lynx 页面默认不渲染原生标题栏；
- OTA Store v2 的 App ID 物理隔离、current/previous 保留和无候选版本模型；
- App ID 级 staging、冷启动 orphan 清理、statfs 容量预检和进程内 Release lease；
- Launcher/Native Tab 只读 OTA 磁盘 Inspector；
- JSON、SVG、Bash、源码分隔符和中文注释检查；
- 生成 ZIP 后解压复验。

## 构建与运行

已执行：

- HAR：`assembleHar --mode module -p module=lynx_shell_kit@default`；
- App：`assembleApp --no-daemon`；
- HarmonyOS Pura 90 模拟器 `127.0.0.1:5555 TCP Connected localhost` 安装并启动未签名 `.app`；
- `main.lynx.bundle` 与 `nav-chain.lynx.bundle` 首屏渲染，`containerID`/`routeKey` 已进入页面全局属性。

本轮 OTA Store v2 已在 Pura 90 模拟器用 `env=TEST` 的显式 Mock Source 完成运行态验收。卸载重装后
全量 Mock 同步产生 `mock-ota-v1`，再次同步产生 `mock-ota-v2`；Inspector 观察到两个 App ID 各自拥有
current/previous，分别为 7 个文件和 5 个文件，共 12 个文件。Native Tab 进入 Inspector 时 current
显示 `leased`，返回原生壳后 lease 消失；Inspector 刷新前后快照一致且不触发网络；删除远程文件后
远程文件数为 0，rawfile embedded 页面仍能渲染；强制停止并冷启动后 current/previous 仍可直接加载。
这证明新 Store v2 的 App ID 隔离、保留上限、Tab cache-only、主动刷新、Inspector、lease、删除和冷启动
链路。Mock 复用了已验真的 rawfile bytes，主要用于验证存储/生命周期契约，不等价于真实服务端内容差异。

真实 TEST OTA 服务在本次 Mac 请求中返回 TLS `SSL_ERROR_SYSCALL`（HTTP code 000），且当前没有物理
Harmony 设备；因此真实 Server 版本切换、物理真机行为和发布签名包仍标记为待确认。旧全局 Store 布局
的历史运行记录不能作为本轮证明。

未覆盖：签名发布包、9 类 XElement 的完整交互矩阵、所有导航按钮的逐项真机回归和媒体/文件真实业务链路；
因此构建/运行结论限定于当前模拟器与已验证 Bundle，媒体五项仍按 `1004` 明确降级。服务端当前每个
App ID 只有一个 latest，两个不同远程版本之间的 previous 回滚仍需服务端准备版本后复验。
