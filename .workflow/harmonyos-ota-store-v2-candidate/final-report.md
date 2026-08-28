# Final Report: HarmonyOS OTA Store v2 无 Candidate 对齐

## Outcome

代码、构建和模拟器运行态完成；真实 OTA Server 与物理 Harmony 设备仍是独立待验收边界。HarmonyOS
不包含 candidate/trial。

## Accepted Results

- iOS 已先提交：`05d2e67 Codex 提交：完成 iOS OTA Store v2 实现`。
- Harmony Store v2 源码、模型、Runtime、Page/Tab lease、Inspector 和文档已完成。
- 静态检查 85 PASS；三端静态汇总 196 PASS。
- HAR 与 App 构建均成功。
- Pura 90 模拟器已安装新包并通过 Store v2 Mock 运行态：两个 App ID 各自保留 mock-ota-v1/v2，
  共 12 个文件；Tab lease、Inspector、删除、rawfile fallback 和冷启动 current 均有证据。

## Rejected Results

- 旧 Harmony 全局 `releases/states` 运行记录不作为新 Store v2 证据。
- Mock 运行态不能替代真实 Server 的版本内容差异，也不能替代物理真机和签名包验收。

## Conflicts Resolved

- 旧全局目录与 Android/iOS App ID 隔离契约冲突：改为 `apps/<appId>/`。
- Harmony 不需要 candidate：删除候选状态空间，只保留 current/previous。
- lease prune 与异步发布可能竞态：统一进入 Runtime operation queue。

## Verification Evidence

详见 `results/H1-discovery.md`、`results/H2-store-runtime.md`、`results/H3-inspector-docs.md` 和
`results/H4-verification.md`。Pura 90 模拟器已连接并完成运行态证据；真实 TEST OTA 请求在本次环境
返回 TLS `SSL_ERROR_SYSCALL`（HTTP code 000），物理设备尚未连接。

## Remaining Risks

- 需要在真实 TEST OTA 服务恢复后执行服务端版本切换与内容差异验收，并在物理 Harmony 设备上复验；
  旧布局历史数据不能替代新路径证据。
- 服务端当前每个 App ID 只有一个 latest，两个不同远程版本的 previous 回滚仍需要服务端准备版本。
- 当前 Harmony 远程服务通过 `serverPlatform=android` 兼容现有服务端；后端开放 harmony 后再切换。

## Reusable Follow-up

真实服务或物理设备可用后按 `docs/harmony-ota-test-report.html` 的 H-09 顺序执行，并把结果回填到 H4
与 `harmony/VALIDATION.md`；不需要修改 Store 结构或引入 candidate。
