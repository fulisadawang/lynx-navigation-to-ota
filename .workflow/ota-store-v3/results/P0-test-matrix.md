# P0 Result — 100→1 测试用例与 Golden Fixture

> 历史说明：本文件的“当前覆盖缺口”是 P0 制定测试矩阵时的缺口清单；P1–P3 已补齐其中可在本地模拟器和受控故障环境完成的项目，剩余边界以 P4 为准。

## 核心结论

当前测试能证明部分 Store v2 的 SHA、current/previous、candidate、lease 和 Native Tab 行为，但不能证明 Store v3 的真正磁盘增量。缺失重点为：100/100 Golden Fixture、CAS 写入计数、对象级磁盘快照、304/ETag、对象写入/rename/Manifest/State 崩溃恢复、Harmony OTA 单元/集成测试。

## Golden Fixture

固定 Fixture：`ota-store-v3-golden-100-v1-v2`。

- V1：100 个 Bundle。
- V2：仍为 100 个 Bundle，只有 `bundle-050` 的内容、SHA 和 URL 改变。
- V1/V2 的 `bundlePath` 集合完全一致。
- 内容由确定性算法生成，不使用时间、随机 UUID 或机器路径。
- 每个平台使用相同的 Bundle bytes/SHA，只有 scope.platform 不同。
- Manifest 保持完整快照，不改成 patch 链。

推荐路径：

```text
pages/10000001/bundle-000.lynx.bundle
...
pages/10000001/bundle-099.lynx.bundle
```

## 100→1 硬门禁

| 指标 | V1 初装 | V2 只改 1 个 |
|---|---:|---:|
| Manifest 条目数 | 100 | 100 |
| 二进制网络下载数 | 100 | 1 |
| CAS 新对象写入数 | 100 | 1 |
| 未变化 Bundle 物理复制数 | 0 | 0 |
| State commit | 1 | 1 |
| V2 完整可路由 Bundle | 100 | 100 |

只证明网络下载数为 1 不够；必须同时证明新增 CAS object 为 1、未变化对象没有复制、磁盘只增加变化对象和少量元数据。

## 必须执行的 P0 用例

1. 完整 V1/V2 Manifest，只有一个 SHA 变化。
2. 空 Store 安装 V1：download=100、CAS write=100。
3. V1→V2：download=1、CAS write=1、copy=0、current=V2、previous=V1。
4. 304/ETag：不下载、不写对象、不写 Manifest、不提交 State。
5. 空数组/定向 404/网络失败：current 保持不变。
6. 错误 SHA/size/空响应/超限：对象不进入 CAS。
7. object write、object rename、Manifest、State 提交前后强杀：重启只能看到合法旧/新状态。
8. 预检通过但写入中 ENOSPC：旧 current 可读，无半对象。
9. lease 存活时 install/delete/GC：活页面对象不能删除，lease 关闭后才回收。
10. 两个 App ID 使用相同 SHA/releaseId：路径、state、缓存和 delete 互不污染。
11. Android/iOS candidate pending/trial/healthy/discard；Native Tab 永不消费 candidate。
12. Harmony 只允许 current/previous，不创建 candidate/trial。
13. 同一 Navigation session 在 V1→V2 激活期间跳转：session 内 releaseId 不漂移。
14. Native Tab 切换网络请求数为 0，主动刷新成功后才创建新 Snapshot。
15. 服务端 latest 从 V10 指向 V5：按明确 ACTIVE/ROLLED_BACK 语义验证 Manifest、对象复用和 GC。
16. App 覆盖安装后：合法 remote current 保留，embedded 不复制到 OTA Store。

## 证据协议

每次测试绑定不含凭证的 `sessionId`，并同时收集：

```text
manifestBundleCount
downloadedBundleCount / downloadedBytes
casWriteCount / casWriteBytes
byteCopyCount / copiedBytes
manifestWriteCount / stateCommitCount
objectCount / objectStorePhysicalBytes / totalStoreBytes
current / previous / candidate / leased
routeResolvedReleaseId / source / bundlePath
```

每个端的 HTML 报告必须包含 expected/actual、HTTP 计数、CAS/磁盘计数、Store 快照、页面版本身份和截图。没有截图、磁盘快照或 session correlation 时只能标记 `BLOCKED`，不能标记 `PASS`。

## 当前覆盖缺口

- Android：已有 JVM/真机历史证据，但没有 instrumentation；当前 v2 预期为 download=1、copy=99，应在 v3 P0 被改为 download=1、CAS write=1、copy=0。
- iOS：已有 Swift/XCUITest 和小规模复用测试，但没有 100/100 CAS、对象故障和对象 GC 量化。
- HarmonyOS：目前主要是静态、HAR/App 和 Pura 90 Mock；没有 OTA 单元/集成 target、真实 Server/签名真机和 fault injection。
- 三端均未形成统一的 OTA sessionId/metrics/HTML 证据协议。

## P0 失败判定

只要出现以下任一情况，Store v3 P0 不通过：半成品 current、缺对象仍可路由、V2 copy 99 个不变对象、Tab 切换联网、session 版本漂移、GC 删除 lease/staging 引用、V10→V5 语义未冻结、报告缺少截图或磁盘证据。
