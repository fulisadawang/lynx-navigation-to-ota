# Integration Checklist: ota-store-v3

## P0 Code Map

# P0 Result — 当前代码与资产映射
## 结论
- 服务端/发布端发送完整快照，`changedBundles` 是历史字段名，不是纯 delta；Playground 发布脚本先合并旧 Bundle 再发布完整列表。
- 网络层在旧 current 的 `bundlePath + SHA` 命中时只下载变化 Bundle。
- Android、HarmonyOS 会把未变化 Bundle 复制到新 staging；iOS 下载阶段复用旧路径，但 Canonical Store stage 仍复制完整集合。
- 稳定磁盘至少保留完整 `current + previous`；candidate、lease、staging 会进一步扩大峰值。
- 路由参数仍是逻辑 `appId + bundleName`，Native Tab 严格 cache-only；当前没有 session 级 OTA Manifest 快照，普通页面可能在版本切换前后分别解析 current。
## 关键调用链
## 精确证据
- Android 旧 Bundle 命中后仍执行 `copyAndHash`：[ReleaseTransaction.kt:998](/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/android/lynx-shell/src/main/kotlin/com/ota/android/sdk/ReleaseTransaction.kt:998)、[ReleaseTransaction.kt:1077](/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/android/lynx-shell/src/main/kotlin/com/ota/android/sdk/ReleaseTransaction.kt:1077)。
- iOS 下载阶段复用旧路径：[OtaSDK.swift:945](/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/ios/OtaIOSSDK/Sources/OtaIOSSDK/OtaSDK.swift:945)；stage 阶段全量 `copyItem`：[CanonicalOtaStore.swift:210](/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/ios/OtaIOSSDK/Sources/OtaIOSSDK/CanonicalOtaStore.swift:210)。
- HarmonyOS 明确把 `changedBundles` 当完整快照，并对 SHA 相同文件执行 `copyFileSync`：[ReleaseTransaction.ets:95](/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/harmony/lynx_shell_kit/src/main/ets/ota/ReleaseTransaction.ets:95)、[ReleaseTransaction.ets:140](/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/harmony/lynx_shell_kit/src/main/ets/ota/ReleaseTransaction.ets:140)。
- 发布脚本把旧清单合并为完整 `completeBundles`：[publish-ota-bundle.mjs:214](/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/playground/scripts/publish-ota-bundle.mjs:214)、[publish-ota-bundle.mjs:268](/Users/nieyutan/Documents/hbc-git/codex/lynx-navigation-to-ota/playground/scripts/publish-ota-bundle.mjs:268)。
## 本地资产盘点
- Playground 有构建和真实 OSS/Admin 发布脚本，但没有本仓库内可直接启动的 `LynxOtaServer`、Docker Compose 或 fixture server。
- 三端都有 embedded Manifest，可复用为独立 embedded baseline；Bundle bytes 从 APK/App Bundle/rawfile 直接读取。
- 三端都有只读 Storage Diagnostics/Inspector，可扩展显示 v3 object、Manifest、lease 和 GC 引用。
- 当前 Android 有 downloaded/copied 统计，iOS 有 downloaded/reused 统计，Harmony 没有跨端一致的 CAS 计数契约。
## P1 iOS 边界
## 约束与风险
- App ID 必须继续物理隔离；不跨 App ID 共享对象。
- 真实服务端不在当前仓库，本地 fixture server 是本轮必要新增能力。
- HarmonyOS `fsync/rename/atomic replace` 的目标 SDK 能力需要在实现和真机阶段验证。
- Demo 可卸载重装切换 schema，不做 Store v2 原地迁移。

## P0 Fixture Server

# P0 Result — Playground Fixture 与本地 OTA Server
## 结果
- 使用 Playground 的 ReactLynx/Rspeedy 编译链生成 V1/V2 Bundle：两个版本各 100 个，只有 `pages/10000001/bundle-050.lynx.bundle` 的 bytes、size、SHA-256 变化。
- `node scripts/verify-ota-store-v3-fixture.mjs --fixture playground/fixtures/ota-store-v3-golden-100-v1-v2`：PASS。
- 本地 Server：`http://127.0.0.1:18765`，仅用于 TEST 验收，不需要凭证。
- latest-bundle-list 返回完整 100 条 `changedBundles`；release Manifest 返回完整 100 条 `bundles`。
- V1/V2 Bundle 二进制可下载；Server 支持 V1/V2 切换、ETag/304、latest/Manifest 404、Bundle 404、断开、错误 SHA/size、空列表和 metrics。
- 已用 curl 验证 health、V1 latest、V1 Manifest、V1 Bundle 下载、切换 V2、V2 完整条目数和请求计数。
## P0 冻结
- Manifest 保持完整快照，不设计 patch/delta 链。
- Server 的 latest index 可以轻量化，但本地激活前必须拿到完整 Manifest。
- v3 客户端对象层按 App ID + SHA-256 CAS 去重；本地 fixture Server 只模拟接口和二进制，不预先模拟客户端存储。
## 运行方式
--fixture playground/fixtures/ota-store-v3-golden-100-v1-v2 \
--host 127.0.0.1 --port 18765
## 边界
- 本地 Server 不等价于真实外部 OTA Server；本轮用于隔离网络环境，保证客户端可以真实走 HTTP 请求、完整 Manifest、Bundle 下载和错误响应。
- 当前客户端仍强制生产 HTTPS；iOS P1 需要增加仅 TEST/Debug 的本地 HTTP 配置入口，Release 保持 HTTPS 拒绝。

## P0 Synthesis

# P0 Result — 综合架构冻结
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
## Decisions
-> 完整不可变 Manifest（100 条逻辑 Bundle 映射）
-> missing ObjectId 集合
-> App ID scoped CAS objects
-> durable Manifest
-> 原子 State current/previous/candidate
-> 新 NavigationSnapshot
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

## P0 Test Matrix

# P0 Result — 100→1 测试用例与 Golden Fixture
## 核心结论
## Golden Fixture
- V1：100 个 Bundle。
- V2：仍为 100 个 Bundle，只有 `bundle-050` 的内容、SHA 和 URL 改变。
- V1/V2 的 `bundlePath` 集合完全一致。
- 内容由确定性算法生成，不使用时间、随机 UUID 或机器路径。
- 每个平台使用相同的 Bundle bytes/SHA，只有 scope.platform 不同。
- Manifest 保持完整快照，不改成 patch 链。
## 100→1 硬门禁
## 必须执行的 P0 用例
## 证据协议
## 当前覆盖缺口
- Android：已有 JVM/真机历史证据，但没有 instrumentation；当前 v2 预期为 download=1、copy=99，应在 v3 P0 被改为 download=1、CAS write=1、copy=0。
- iOS：已有 Swift/XCUITest 和小规模复用测试，但没有 100/100 CAS、对象故障和对象 GC 量化。
- HarmonyOS：目前主要是静态、HAR/App 和 Pura 90 Mock；没有 OTA 单元/集成 target、真实 Server/签名真机和 fault injection。
- 三端均未形成统一的 OTA sessionId/metrics/HTML 证据协议。
## P0 失败判定

## P3 Harmony

# P3 Result — HarmonyOS Store v3
## 结论
## 构建与静态证据
- `assembleHar --mode module -p module=lynx_shell_kit@default --no-daemon`：exit 0，`BUILD SUCCESSFUL`。
- `assembleApp --no-daemon`：exit 0，`BUILD SUCCESSFUL`。
- `python3 harmony/scripts/check_harmony_shell.py --quiet`：`89 PASS / 0 WARN / 0 FAIL`。
- `python3 scripts/static_check_android_ios.py --quiet`：`111 PASS / 0 WARN / 0 FAIL`；跨端静态门禁合计 `200 PASS / 0 WARN / 0 FAIL`。
- `node scripts/verify-ota-store-v3-fixture.mjs`：exit 0；100 个 Bundle，只有 index 050 变化。
- `scripts/ota-store-v3/run-harmony-fault-tests.sh`：10 个 TEST-only 事务/ENOSPC 故障点、capacity=0 和 server disconnect 均执行，并由 `assert-harmony-results.mjs fault` 自动断言通过。
- `scripts/ota-store-v3/run-harmony-process-crash-tests.sh`：5 个提交边界 HDC force-stop 均执行，并由 `assert-harmony-results.mjs process-crash` 自动断言通过；保护启动和正常恢复均为 Bundle=0。
- 删除验收：活体 lease 存在时先保护远程对象；force-stop 后新进程启动恢复并 prune orphan，Inspector 显示 files=0、CAS=0、Manifest=0；直接打开 rawfile baseline 的 OTA 请求为 0。
- NavigationSnapshot：Demo 同 session 连续打开两个 OTA Page，HDC 日志显示两次使用同一个 Snapshot ID；返回宿主页后再打开内置基线创建新的 Snapshot。
- Hvigor 仍输出 Lynx/ArkTS 依赖既有 warning，并提示未配置 `signingConfig`；本轮没有伪造签名发布包。
## 运行态证据
## 已修复的实现问题
## 未覆盖
- HarmonyOS 物理真机、签名发布包和生产外部 Server/CDN/TLS。
- 真实断电/系统级异常终止（HDC force-stop 已覆盖进程终止，但不等同断电）。
- 真实 OS ENOSPC、不同目标 SDK 的 `fsync`/`rename` 兼容性。
- 本轮未在设备上同时安装两个不同业务 App；App ID 隔离由源码门禁和路径实现证明。

## P4 Final Audit

# P4 Result — 最终跨端审计
## 已通过
- Golden Fixture：100 个 Bundle，V1/V2 只有 050 改变，验证脚本 exit 0。
- iOS 静态门禁：111 PASS / 0 WARN / 0 FAIL；Swift 单测 54/54；XCUITest 默认回归 7 passed、0 failed、3 skipped，本地真实 OTA smoke 1 passed、0 failed、0 skipped。
- Android 静态门禁：已包含在跨端 `111 PASS / 0 WARN / 0 FAIL`；Store v3 JVM 47/47，0 failed、0 skipped；Debug APK 构建成功。
- Harmony 静态门禁：89 PASS / 0 WARN / 0 FAIL。
- 三端汇总静态门禁：200 PASS / 0 WARN / 0 FAIL。
- 三端均完成本地 Golden Fixture V1 全量 100 个 Bundle → V2 只请求并写入 050 的 1 个变化对象；完整 Manifest 仍为 100 条，未变化 Bundle 复制数为 0。
- iOS、Android、HarmonyOS 均验证 Native Tab 普通切换零 OTA 请求、主动刷新重建内容、冷启动读取已提交版本和 ETag 304。
- Harmony TEST-only 故障矩阵：10 个事务/ENOSPC 故障点 + capacity=0 + disconnect，均有 JSONL 结果和自动断言。
- Harmony HDC force-stop 矩阵：5 个 Object/Objects/Manifest/State 暂停边界，保护启动和正常恢复通过；恢复阶段 Bundle=0、CAS=101。
- Harmony 删除/回收/内置基线：delete → force-stop → 空 latest 启动后 files=0、CAS=0、Manifest=0；rawfile 直读没有 OTA 请求。
- Harmony NavigationSnapshot：同 session 双 Page 复用同一个 Snapshot ID，退出后新 session 建立新 Snapshot。
- 三份独立 HTML 报告、截图和本地 JSONL/文本证据均存在；报告中的相对图片/实现/结果链接通过引用校验。
- `git diff --check`、JavaScript 脚本语法检查和 workflow artifact 校验通过。
## 运行态边界
- iOS：iPhone 16 Pro / iOS 18.1 Simulator；本地 URL 仅由测试 harness 注入。
- Android：`emulator-5554` / Android API 35 arm64 模拟器；使用独立 ADB 端口避免 AndroMeld ADB 服务互相抢占。
- HarmonyOS：DevEco 模拟器 `emulator` / HarmonyOS 6.1.0.126；HDC `127.0.0.1:5557`；最终产物为 unsigned `.app`。
- 本地 Fixture Server 只替代外网 OTA 服务，不替代真实生产 CDN/TLS；Harmony Demo 为复用当前 Fixture，向 Server 请求 `platform=android`，宿主页面身份仍是 HarmonyOS。
## 仍然明确标记为 BLOCKED
- HarmonyOS 物理真机和三端签名发布包。
- 真实断电/系统级异常终止；HDC force-stop 只能覆盖进程终止路径。
- 真正的 OS ENOSPC 中途写入，以及不同目标 SDK 的 `fsync`/`rename` 兼容性。
- 本轮没有在设备上同时安装两个业务 App 做双实例物理隔离；App ID 作用域由源码门禁和路径实现覆盖。
- 生产外部 OTA Server/CDN/TLS 的真实环境验收。

## Integration Decisions

Accepted:

Rejected:

Conflicts:

Remaining risks:

Verification still needed:
