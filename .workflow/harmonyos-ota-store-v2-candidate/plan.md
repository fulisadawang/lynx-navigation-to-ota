# HarmonyOS OTA Store v2 无 Candidate 对齐

## Goal

让 HarmonyOS 的 OTA/Router/ArkUI Container 与已完成的 Android、iOS Store v2 行为一致：按
`lynxAppId` 隔离远程 Release、只保留 `current/previous`、用 lease 保护活体页面、冷启动清理
orphan/staging、embedded rawfile 不复制到私有磁盘，并提供原生只读磁盘 Inspector。HarmonyOS
明确不实现 candidate、trial、candidate 指针或候选版本 API。

## Success Criteria

1. `apps/<appId>/releases/<releaseId>` 是唯一远程物理布局；相同 Release ID 在不同 App ID 下互不覆盖。
2. Store schema v2 的 `apps/<appId>/state.json` 只保存 current/previous；不创建 `candidate.json`。
3. 连续 V1…V10 后只保留 V9/V10；staging 事务失败或冷启动后不会残留。
4. embedded Bundle 继续直接从 rawfile 读取，私有目录只保存远程 OTA 文件和状态元数据。
5. 普通 Page 与 ArkUI Tab 持有远程 Release lease；最后一个 lease 释放后才回收无引用 Release。
6. 启动/回前台/主动刷新请求全量 latest-bundle-list；Tab 切换只读 current，不请求网络、不 repair。
7. 下载前执行 prune 和可用空间预检；容量不足时旧 current 保持不变。
8. Launcher 与原生 Tab 可进入只读 Inspector，展示真实路径、版本角色、文件树、字节数和 lease。
9. Harmony 静态检查、HAR/App 构建、可用模拟器运行和 Store v2 契约验收全部有记录。

## Current Context

- iOS 已提交：`05d2e67 Codex 提交：完成 iOS OTA Store v2 实现`。
- Harmony 当前代码仍是全局 `releases/`、`states/`、`.staging/`，需要迁移；Tab 尚无 lease。
- 服务端测试环境通过 `serverPlatform=android` 提供现有 release 数据，宿主仍报告 `harmony`。

## Constraints

- 不修改 Android 既有实现；Android 工作树中的未提交改动属于上一阶段。
- 不引入 candidate；不保留 candidate 字段、文件、状态、接口或文档示例。
- Demo 不做旧 Store 迁移；通过卸载重装获得空沙盒，直接使用 schema v2。
- 保留现有 ArkUI Tabs 承载方式；不把原生 TabBar 责任移入 Lynx。
- 不提交或输出 OTA/CI token；不执行 push/merge。

## Risks

- HarmonyOS API 与 iOS/Android 文件语义不同，必须用 `fs`/`statfs` 已确认的 API 实现原子写入和容量查询。
- ArkTS 没有 iOS `deinit` 同构语义，必须覆盖 `aboutToBeDeleted`、取消请求和 generation 失效路径。
- 未配置 HarmonyOS 自动化测试框架；运行态证据可能需要 DevEco/hdc 和人工 UI 检查，不能冒充自动化。

## Approval Required

用户已授权实现；本轮涉及的本地代码、测试、构建和模拟器安装均在仓库范围内，无新的外部写入。

## Work Packets

- H1：盘点旧 Harmony Store、Runtime、Container、Tab、Router 和构建边界（已完成）。
- H2：实现 Store v2 核心、无 candidate、lease、prune、capacity（进行中）。
- H3：接入 Launcher/Native Tab Inspector 与文档（待执行）。
- H4：静态、HAR/App、模拟器/hdc、报告与 Obsidian 收口（待执行）。

## Integration Policy

- 先更新模型和 Store，再接 Runtime/Container，最后接 UI；每个包独立记录结果。
- 以 Android/iOS 已验证契约为行为事实源，不复制平台 API 细节。
- 任何失败回到对应 packet 修复；不通过修改静态检查器隐藏失败。

## Verification

```text
python3 harmony/scripts/check_harmony_shell.py
python3 scripts/static_check.py
hvigorw assembleHar --mode module -p module=lynx_shell_kit@default --no-daemon
hvigorw assembleApp --no-daemon
hdc install -r <app>
hdc shell ... 运行态/日志/目录证据
git diff --check
```

## Reusable Artifacts

- `.workflow/harmonyos-ota-store-v2-candidate/final-report.md`
- `harmony/README.md`、`harmony/VALIDATION.md`、`docs/lynx-bundle-paths.html`
- 原生 Inspector 作为后续 Harmony 宿主接入的最小诊断模板。
