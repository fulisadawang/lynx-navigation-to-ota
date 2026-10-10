# iOS 最终独立 Change 复审

审查角色：`ios-swift-auditor`；任务 `/root/ios_final_matcher_review`。对象为 `codex/bundle-loading-opt` 的最终工作区 diff，相对远程 main 基线 `b3837d491069dd5409d78dad75276201c54edaa3`。只读 source、直接调用者和现有证据；无产品修改、无新构建、无测试或设备操作。

## 结论

在已审范围内未发现新的 P0/P1/P2/P3 阻断项；前置 iOS 独立审查提出的 byte/path 歧义 P2 已关闭。

## 核查事实

- `OtaPreparedAsyncIndex.entry` 将完整 URL 候选与规范化 requestKey 候选以 Set union 合并，只接受唯一 entry；byte 和 path 均走这一入口，生产 pathResolver 优先于 localPaths 字典覆盖结果。
- 两个 path 用例已取得真实 Red；最终 Core 日志为 107 tests / 13 suites 全通过，包含重复 URL 与 URL/path 冲突的 byte 抛错、path nil 双断言。
- prepareIndex 保留 schema、owner、requestKey、SHA 名称、大小/类型检查及当前 owner 对象 size/SHA；固定不可变索引捕获 release 对象根，byte 每次读取目标仍验证。path 保持准备期内容校验，README 与实际行为一致。
- PreparedResources 在原锁内同步置 closed，新请求拒绝；activeResolves 结束后一次性清理，按 lease close → prune → onDrained 顺序执行。直接 runtime 调用者预先注册 snapshot token 的 drain 回调，导航 snapshot 保留至 token 归还，未出现提前删资源窗口。
- Tab detached 读取前后仍检查取消，提交 UI 前继续核对 generation 和身份 epoch；pending 资源由 defer 释放，reload 取消旧任务并 invalidate generation。系统同步文件读取本身不能中途抢占，报告没有宣称可抢占 I/O。
- 新索引和 initializer 增量均为内部实现，无公开 Pod/Router/Bridge 方法变化。诊断 observer 全部 DEBUG，事件不含 URL、请求头或用户信息。
- 归档两版各 78 条/60 正式，所有 Tab 读取由主线程变为后台；13 个 App 实际输入 size/SHA 相同，真实 Large/Async Native 回执正确。只读审查复核这些记录，不构成新增设备证明。

## 性能与剩余边界

报告如实保留更慢 case：Async Tab 配对首屏 p95 28.370 → 41.624 ms，业务 ready p95 47.096 → 75.703 ms。限定功能/线程归属通过不等于首屏、RSS、十页内存或无泄漏通过。

未覆盖：真机、签名/Release 产物、完整既有 NativeReadiness 套件、低磁盘、十页并存/返回、footprint/RSS、长期泄漏和稳定生产 p95。
