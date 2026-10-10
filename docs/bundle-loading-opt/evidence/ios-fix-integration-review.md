# iOS 歧义修复后的整合复核

复核对象：`codex/bundle-loading-opt` 当前实际 diff，相对 `b3837d491069dd5409d78dad75276201c54edaa3`。主 Agent 只读核对最终索引、PreparedResources、Tab 读取、README 和最终执行记录，未追加产品修改。

## 结论与职责边界

原 iOS 专项独立审查发现的 P2 已修正：重复完整 URL、完整 URL 与另一条 requestKey/path 同时命中时，byte 和 localURL 现在均拒绝。修正前两项 path 断言取得真实 Red；修正后完整 Core 107 tests / 13 suites 通过，最终模拟器宿主 3/3 通过。

本文件是主 Agent 整合复核；其后 `ios-swift-auditor` 已独立核对最终实际 diff、直接调用者和归档证据，确认 P2 已关闭、已审范围无新阻断项。该专项没有追加构建或设备运行，不将只读复审当成新增设备证明。

## 核对结果

- `OtaPreparedAsyncIndex.entry` 合并完整 URL 候选与规范化请求键候选，用 Set 去重同一条，只有一条时接受。byte resolve 与 localURL 共用这一函数，字典覆盖不再绕过歧义。
- `prepareIndex` 读取并校验清单，decode 与 schema/owner/requestKey 验证后才创建页级不可变索引；当前 owner 的对象仍核对 size/SHA。不是跨页面的可变 current 缓存。
- `resolve(index:)` 每次通过原 `verifiedData` 检查目标 size/SHA，不保存目标字节。`localURL` 保持原准备期内容校验政策，不新加同步对象读/SHA；README 与实现相符。
- `OtaPreparedResources.localURL` 仍先在原锁内检查 closed；新增内部 pathResolver 纯查询，没有 await 或磁盘读取。`beginResolve`、`finishResolve`、activeResolves、close/drain 与 lease 清理顺序未改。
- Tab 的主文件读取使用普通 Page 已有的 detached 模式；父任务在 await 前后检查取消，后续 generation/身份门禁继续阻止迟到结果 render。detached 同步读取本身不承诺中途取消，取消边界与 Page 保持一致。
- 诊断 observer 全部在 DEBUG，内部类型，无公开 Pod/Router/Bridge ABI 变化；记录不含 URL、请求头或用户信息。
- Pod lock 仅对齐基线已经声明的自有 path Pod 1.1.0，没有升级 Lynx/PrimJS。

## 尚不能得出的结论

模拟器数据不能证明整体首屏加速：首轮部分组更慢，Async Tab 配对复测的 p95 仍高于基线。没有 App footprint/RSS 峰值、十页并存/回退后的内存曲线、真机 FPS 或泄漏证据；本复核不授予这些结论。
