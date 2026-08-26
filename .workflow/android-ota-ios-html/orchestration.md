# Orchestration: Android OTA 与 iOS 一致性实现、真机验收和 HTML 报告

## Execution Rules

- Keep the original objective intact.
- Ask for approval before risky, expensive, external, or destructive actions.
- Keep immediate blocking work local.
- Delegate only bounded, disjoint, materially useful packets.
- Integrate packet results before final verification.

## Branching Rules

- 若 Android 已有对应状态机：只补齐证据、Tab 统一解析、测试和报告。
- 若 Android 缺少 iOS 已有的 previous/embedded rollback：先最小实现状态转换和可测试 fault hook，再跑单测。
- 若真实服务不可达：不阻塞本地流程，使用受控 mock；live 结果单独标记为 skipped/unavailable。
- 若真机包无法构建或安装：保留静态/单测/build 证据，报告中不能写成 device pass。
- 若 worker 试图触碰重叠 runtime 文件：拒绝其写入，主线程整合。

## Packet Prompts

### android-code-map

只读检查 Android OTA SDK/runtime、Bundle Registry、Tab Fragment、Activity 生命周期、内置 assets、校验缓存和 iOS 对应实现。输出：调用链、身份来源、current/previous/embedded 优先级、网络 gate、缺口和最小建议。不要改文件，不要运行外部写操作。

### android-test-contract

只读读取 iOS UI/SDK 测试和 Android 现有测试/脚本，建立 Android 对等用例表：用例 ID、前置、动作、预期、证据层级、可自动化位置和风险。特别覆盖版本展示、Tab vs 单开一致性、启动同步、主动刷新、回滚和进程终止恢复。不要改文件。

### android-test-harness

只修改 Android 测试目录和明确的测试报告输入文件；不要修改 runtime、gradle 生产配置或用户已有文件。补齐可安全落地的 JUnit/instrumented/fixture 测试；若生产代码缺 hook，记录 gap 而不是臆造。每个改动列出路径和验证命令。

## Completion Audit

- [ ] 三个 packet 均有独立结果文件并已整合。
- [ ] Android 与 iOS 的行为差异已逐项裁决。
- [ ] Android runtime/Tab/版本展示的必要改动已完成。
- [ ] 单测、静态、构建和 AndroMeld 真机证据已记录。
- [ ] live OTA 与 mock/no-token 边界已记录。
- [ ] Android HTML 报告已生成、自检、无 token。
- [ ] `state.json`、`final-report.md`、Obsidian 高价值记录（如需）已更新。
