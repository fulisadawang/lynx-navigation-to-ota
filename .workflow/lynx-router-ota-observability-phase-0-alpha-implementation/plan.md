# Lynx Router OTA Observability Phase 0 Alpha Implementation

## Goal

在分支 `feature/telemetry-phase0-alpha` 上，按 Obsidian D2 技术方案落地可验证的 Phase 0 契约和
Phase 1 本地 Alpha 基线：三端共享事件/身份/Bundle Snapshot 语义，原生采集器不影响 Router、OTA
和 Lynx 首屏，默认不联网、不接生产 durable uploader。

## Success Criteria

- 新分支建立并保留用户原有未提交改动。
- 有机器可校验的 Wire Schema 3.0.0、Remote Config Schema 1.0.0 和 golden fixtures。
- Android、iOS、HarmonyOS 各自拥有最小的本地 Telemetry Coordinator/Tracker 入口，字段语义不分叉。
- `entryId/pageViewId/renderAttemptId/activationId`、Attempted/Resolved Bundle Snapshot、
  navigation admission/transition terminal、page/app state 和 sampling cohort 有单测或 fixture 验证。
- 默认 no-op/Debug Sink；任何 Collector/Observer 故障不得阻塞页面导航、OTA 或 Lynx 渲染。
- 通过静态检查、目标模块编译/单测（可用时）并清楚标记未验证的平台运行项。

## Current Context

- 目标仓库：`/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota`。
- 旧仓库 `LynxScreens-Android` 不得修改。
- Obsidian 方案：`/Users/nieyutan/Documents/Obsidian Vault/前端技术/Lynx/Lynx-4.0-三端Router-OTA生产监控与元素曝光完整技术方案.md`，D2。
- 当前 main 上有用户未提交的 `PROJECT_MAP.md`、`README.md` 和 `BUNDLE_GLOBAL_ACCELERATION.md` 改动，必须保留。
- 独立仓基线为 `608d0e4`，本次工作分支已创建。
- 当前 Lynx Native 目标为 4.0.0；具体独立仓依赖和三端 ABI 仍需由 capability probe 重核。

## Constraints

- 简体中文核心注释；不上传 token、URL query、params、原始 Error、完整 Performance Record、绝对路径。
- 不修改 OTA 的主下载/激活/回滚语义，不把监控失败抛回页面。
- 不引入 Fragment/ViewStack；沿用 Android Activity-first、iOS UIViewController、HarmonyOS Page。
- 不在本阶段接生产网络、Maven、GitHub 外部写入或真实服务端数据。
- 各 Worker 不是独占仓库：不要回滚其他人的改动，遇到并行改动要适配；严格遵守分配文件范围。
- 任何未编译/未真机验证项必须标记 `[待确认]`。

## Risks

- 三端 Lynx 4.0.0 API 文档与实际 header/ArkTS 类型可能漂移。
- 当前用户脏改动与新增文件可能并行出现冲突。
- Phase 1 仅实现本地 Coordinator，不能提前宣称生产 durable、端到端上传或曝光 GA。
- iOS/Harmony 构建工具链和依赖可能不可用；失败要分层报告。

## Approval Required

用户已明确授权“新分支 + 按方案执行 + 多个子线程”，因此本次允许创建本地分支、创建工作流产物和
并行修改分配范围内的源码；不允许外部发布、推送、删除或覆盖用户未提交内容。

## Work Packets

### P0-CONTRACTS

- Owner：Shared contracts worker
- Scope：`schemas/telemetry/`、`fixtures/telemetry/`、`docs/telemetry/`（仅新增/修改分配目录）
- Deliver：Wire Schema 3.0.0、Remote Config Schema 1.0.0、身份/状态/Bundle Snapshot fixtures、
  Schema 校验脚本或最小测试、中文说明。
- Do not：修改 Android/iOS/Harmony 源码、引入服务端、写入密钥。

### P1-ANDROID

- Owner：Android worker
- Scope：`android/lynx-shell/src/main/java/**/telemetry/`、对应 `android/lynx-shell/src/test/`，以及
  最小注册适配所需的 Android telemetry 接入文件；不改 OTA 下载算法和无关页面。
- Deliver：Kotlin identity/snapshot/state/event model、Coordinator + no-op/debug sink、中文注释、
  纯逻辑单测；如果现有 API 不适合接线，留下 typed adapter/gap，而不是伪造已接通。
- Do not：修改 iOS/Harmony、上传网络、改变 Router open callback 语义、回滚并行改动。

### P1-IOS-HARMONY

- Owner：iOS + Harmony worker
- Scope：`ios/LynxShellKit/Telemetry/`、对应 Swift 测试，以及
  `harmony/lynx_shell_kit/src/main/ets/telemetry/`、对应测试/配置；三端共享契约以 P0 fixtures 为准。
- Deliver：两端最小 identity/snapshot/state/coordinator、no-op/debug sink、中文注释和可用的纯逻辑测试；
  平台 hook 只接到已有生命周期，不伪造 Performance/transition ABI。
- Do not：修改 Android、改变 OTA/Router 主链、上传外部系统；对于不可编译的 ArkTS 能力保留明确 gap。

## Integration Policy

- Worker 只提交自己分配目录的变更，根 Agent 负责跨端命名、字段、Schema 和构建整合。
- 冲突按 D2 方案、实际 SDK header/types、当前源码三者优先级处理，不能按模型猜测处理。
- Shared schema/fixtures 是跨端唯一事实源；平台模型可有类型差异，但 wire 字段必须一致。
- 内部 delivery 与 external durable reporter 不同时实现；本阶段只允许 no-op/debug/local memory。

## Verification

- 先运行 workflow artifact 校验、Schema/fixture 校验和静态搜索。
- 再按工具可用性运行 Android unit test/compile、iOS build/test、Harmony build/test。
- 不把静态检查当作真机验收；没有真实设备证据的项目标 `[待确认]`。
- 记录 accepted/rejected/conflicts/remaining risks 到 `.workflow/.../final-report.md`。

## Reusable Artifacts

- `.workflow/lynx-router-ota-observability-phase-0-alpha-implementation/` 工作流记录。
- `schemas/telemetry/` 和 `fixtures/telemetry/` 可供后续三端契约测试复用。
- 后续 Phase 2 才能补 durable queue、Batch/ACK、Remote Config 生产上传；不在本次 Alpha 中伪造。
