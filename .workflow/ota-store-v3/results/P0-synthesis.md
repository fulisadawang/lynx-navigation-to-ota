# P0 Result — 综合架构冻结

> 历史说明：本文件先记录实现前的 v2 基线和 v3 设计决策；最终实现与验收结果以 P3 Result、P4 Final Audit 和三份 HTML 报告为准。

## Accepted

- 三端当前是 Store v2：完整 Release Manifest + App ID/Release 自包含目录；网络可以复用同 SHA，但未变化 Bundle 仍会物理复制。
- `changedBundles` 在当前协议中实际承载完整 Release 快照；v3 保留完整 Manifest，不引入 patch 链。
- 目标存储改为 App ID 内部 SHA-256 CAS Object：相同 App ID、相同 SHA 只保存一个对象；不同 App ID 即使 SHA 相同也不共享。
- State v3 只原子引用 Manifest；Bundle 绝对路径不进入 State、路由参数或页面持久化数据。
- Native Tab 继续 cache-only；普通导航 session 和 Tab group 通过 NavigationSnapshot 固定同一个 Manifest 版本。
- GC 从 current、previous、candidate、active lease、staging transaction 重新构建引用集合，不以持久化 refcount 为唯一事实。
- embedded assets/App Bundle/rawfile 继续 no-copy，不进入 CAS。

## Rejected

- 不继续把 99 个未变化 Bundle copy 到新 Release。
- 不让 V2 只保存一个变化 Bundle 并在运行时向 V1 回溯。
- 不使用旧 Release 绝对路径、硬链接或 symlink 作为跨版本一致性方案。
- 不把 Manifest 设计成长期 patch 链；Manifest 传输可以用 lightweight latest index + ETag，但激活前必须得到完整逻辑快照。
- 不让每次页面跳转重新读取 current；不让 Tab 普通切换触发 sync/repair。
- 不让 HarmonyOS 增加 candidate/trial。
- 不把本地 fixture server 的通过结果表述为真实外部 OTA Server 通过。

## Conflicts

1. `changedBundles` 的名字像增量列表，但发布脚本会先合并成完整 `completeBundles`；最终按完整快照解释，并在 v3 内部统一为 `bundles`。
2. 当前 iOS/Android/Harmony 的 lease 保护完整 Release 目录；v3 lease 升级为 Manifest Snapshot lease，同时保护其 Object 引用。
3. 当前 iOS 的 candidate 是独立文件，v3 设计为同一原子 State 内的 candidate 引用；Harmony State 不出现 candidate 字段。
4. 当前容量预检按目标完整 Release；v3 改为缺失 Object bytes + 元数据/安全余量，但仍需验证中途 ENOSPC。

## Decisions

```text
latest index（轻量、支持 ETag/304）
    -> 完整不可变 Manifest（100 条逻辑 Bundle 映射）
    -> missing ObjectId 集合
    -> App ID scoped CAS objects
    -> durable Manifest
    -> 原子 State current/previous/candidate
    -> 新 NavigationSnapshot
```

V1=100、V2 仅变更一个 Bundle 时，P0 硬指标固定为：

```text
Manifest 条目：100 -> 100
二进制下载：100 -> 1
CAS 新对象写入：100 -> 1
未变化对象复制：0 -> 0
V2 可路由 Bundle：100/100
```

服务端 V10→V5 的语义固定为：只有 `ACTIVE V5` 才能作为新目标安装；`ROLLED_BACK`/`DISABLED` 只跳过目标并保留 current。客户端不按 releaseId 数值大小判断新旧。

## P0 交付物

- 完整测试用例：[docs/lynx-ota-store-v3-test-cases.md](../../../docs/lynx-ota-store-v3-test-cases.md)。
- 当前代码映射：[P0-code-map.md](P0-code-map.md)。
- 测试矩阵：[P0-test-matrix.md](P0-test-matrix.md)。
- 本地 fixture server 和 Playground 100 Bundle 需要在 P0 余下阶段新增，未完成前不解锁 iOS 实现。

## P1/P2/P3 边界

- P1 iOS：只允许修改 iOS SDK Store/HTTP/diagnostics/tests，以及随后明确的 iOS Runtime/Container/Tab Snapshot 接线；不碰 Android/Harmony。
- P2 Android：iOS P1 全部门禁通过后，接入同一 fixture 和指标；不得引用 iOS 结果代替 Android。
- P3 HarmonyOS：Android 全部门禁通过后接入；只保留 current/previous，不创建 candidate。
- P4：只做跨端汇总和报告审计，不引入新的架构方向。
