# Android OTA 与 iOS 一致性实现、真机验收和 HTML 报告

## Goal

让 Android 的 OTA + Bundle 容器行为与已验证的 iOS 契约一致：内置 baseline、启动/前台全量同步、Tab cache-only、单独打开 Bundle、版本优先级、候选版本故障回滚、进程终止恢复、可辨识版本信息，并用真实 Android 设备完成验收，最终输出中文可交互 HTML 报告。

## Success Criteria

- Android 代码路径与 iOS 的 current/previous/embedded/rollback 语义一致，不能以“能编译”代替行为一致。
- Tab 页面不在每次切换时请求 OTA；启动或回到前台完成全量同步，用户主动刷新可以触发同步；下一次冷启动/主动刷新才使用已下载的新 Bundle。
- Tab 承载和单独打开使用同一 Bundle 解析、校验、优先级和 fallback 规则。
- 首屏失败可回滚到 previous，previous 不存在时回退 embedded；提交 current 后进程终止可在下一次启动恢复。
- Android 单测/静态检查/构建通过；真实 Android 设备通过启动、版本展示、Tab、刷新和 OTA smoke；失败或不可执行项在报告中明确标记。
- `docs/android-ota-test-report.html` 为 standalone、中文、可交互，包含测试用例、证据层级、设备、真实服务结果和未覆盖项。

## Current Context

- 当前分支：`codex/ios-ota-fault-reliability`；保留现有用户改动，Android 改动只触及必要文件。
- iOS 已有真实服务 live、mock、无 token 三组 UI 结果和 `docs/ios-ota-test-report.html`，Android 以其行为契约和证据结构为基准。
- AndroMeld 已连接一台 Android 真机：后续以工具返回的设备信息为准，不使用通用 adb 输入控制。
- 真实 OTA 服务由用户提供并授权用于测试；凭证只通过运行时环境传入，不写入仓库、报告或 Obsidian。

## Constraints

- 默认简体中文；不改无关平台，不回滚用户已有改动。
- 不能臆造 appId；Bundle 身份使用服务响应/内置 registry 的 identity。
- Tab demo 需要原生承载容器能力，但不改变“TabBar 是否原生”的既有产品约束；demo 可用原生 BottomNavigation 仅作为验收入口。
- 只在用户授权范围内操作 Android 真机；不清理整机数据，不执行无关外部操作。

## Risks

- Android 现有实现可能只有 cache-first + 30 分钟页面 gate，没有 iOS 对应的 candidate/rollback 状态机，需要先以代码事实确认缺口。
- 真机可能无法访问测试 OTA 服务；若服务不可达，报告必须区分 mock、静态、构建和真实网络证据，不能把 mock 结果冒充 live。
- Playground 的 Bundle 可能不是当前 OTA appId；必须从 manifest/响应/registry 读取身份，避免把 demo 入口常量扩散到 runtime。
- 当前 Android 工程可能没有现成 instrumented UI test target；需要选择可验证的 JUnit、Robolectric/原生 UI 或 AndroMeld 真机证据，并标注边界。

## Approval Required

用户已明确授权使用 `code-mapper`、`test-engineer`、`test-automator` 进行 mixed 工作，并授权使用真实 OTA 服务进行测试。不会把 token 写入文件或提交。

## Work Packets

1. `android-code-map`：只读梳理 Android 与 iOS 的 OTA、Bundle Registry、Tab、缓存校验和生命周期差异，输出具体文件/方法/缺口。
2. `android-test-contract`：只读把 iOS 已通过的用例映射为 Android 测试矩阵，区分 SDK、静态、构建、真机和 live OTA 证据。
3. `android-test-harness`：只负责 Android 测试代码/fixture/报告输入的自动化补充，不改 runtime 生产逻辑；若发现必须改 runtime，输出 gap 供主线程整合。
4. 主线程实现：依据两个只读结果补齐 Android runtime、Tab 统一解析和 debug 验收入口，并整合自动化测试结果。
5. 主线程设备验证：通过 AndroMeld 启动 demo、观察 UI、逐步操作并记录版本/Tab/刷新/live OTA 证据。
6. 主线程报告：生成 `docs/android-ota-test-report.html`，运行 workflow completeness 与报告自检。

## Integration Policy

先接受代码事实，再接受测试契约；任何 worker 结果都必须回到主线程核对。生产 runtime 只由主线程整合，测试 worker 不得覆盖已有用户改动。若 Android 与 iOS 语义冲突，以当前 iOS 已验证实现和 Android 现有服务契约共同裁决，并在报告记录决定。

## Verification

- workflow：`verify_workflow.py`、`collect_results.py`。
- static：Android/iOS 静态检查（如仍适用）及 secrets 扫描。
- tests：Android SDK JUnit、既有模块测试、必要的脚本/fixture 检查。
- build：Android debug assemble/installable artifact。
- device：AndroMeld 真机 launch/observe/UI action/wait stable；版本可见、Tab 可见、刷新后版本行为可见。
- live：真实 OTA 请求只在环境变量提供 token 时执行；不可达则使用受控 mock 并明确标记。
- report：HTML 无外部资源、ID/筛选/脚本闭合，内容不含 token。

## Reusable Artifacts

- `.workflow/android-ota-ios-html/`：计划、packet、结果、最终审计。
- `docs/android-ota-test-report.html`：Android 端可交互验收报告。
- 如形成稳定 Android 验收命令，再补充到 Android README/脚本说明，避免保存凭证。
