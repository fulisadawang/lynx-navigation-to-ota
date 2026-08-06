# HarmonyOS 验收范围

当前静态结果：`50 PASS / 0 WARN / 0 FAIL`；检查器已按 Module 化后的实际
`parameter.json=4.0.0` 依赖口径更新。

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
- JSON、SVG、Bash、源码分隔符和中文注释检查；
- 生成 ZIP 后解压复验。

## 构建与运行

已执行：

- HAR：`assembleHar --mode module -p module=lynx_shell_kit@default`；
- App：`assembleApp --no-daemon`；
- 模拟器 `127.0.0.1:5555` 安装并启动未签名 `.app`；
- `main.lynx.bundle` 与 `nav-chain.lynx.bundle` 首屏渲染，`containerID`/`routeKey` 已进入页面全局属性。

未覆盖：签名发布包、9 类 XElement 的完整交互矩阵、所有导航按钮的逐项真机回归和媒体/文件真实业务链路；
因此构建/运行结论限定于当前模拟器与已验证 Bundle，媒体五项仍按 `1004` 明确降级。
