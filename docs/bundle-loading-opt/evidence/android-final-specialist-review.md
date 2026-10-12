# Android Bundle 加载优化最终 Change 复审

审查 checkout：`/Users/nieyutan/.codex/worktrees/bundle-loading-opt/lynx-navigation-to-ota`，分支 `codex/bundle-loading-opt`，比较基线 `b3837d491069dd5409d78dad75276201c54edaa3`。本轮只读最终工作树 diff、相关生产调用者、新增测试源码和已有 Red/Green 日志；没有修改产品/测试源码，没有重新编译、运行测试或操作设备。

## 结论：在已审范围内未发现阻断项

上一轮发现的 P2（`close()` 清空预置 bytes 后，已排队任务可能 fallback 到 URL 加载）已按原触发条件修复并以确定性 Red/Green 关闭。`ShellTemplateProvider`、Store/Sidecar 同次 Manifest 复用及独立 INFRA 修正未发现新的正确性、安全或兼容性阻断项。

## 已关闭 finding

### P2 RESOLVED — queued close 不再触发 fallback、网络或迟到 callback

- **原触发条件**：`loadTemplate()` 已把预置 bytes 请求提交给共享 executor、任务尚未执行，Activity/Tab 随后 `close()` 并清空 `preparedBytes`。旧优化版任务执行时以可变 source 是否非空决定分支，因而落入 `load(uri)`；HTTPS 会在 close 后尝试连接。
- **修复证据**：[代码事实] Provider 现在用构造期不可变 `hasPreparedSource` 判断本实例是否具有预置来源，不再用会被 close 清空的字段决定 fallback；executor lambda 入口先复核 `closed`；取得单次 claim 后立即把 bytes 移到局部变量并清源，若此时已关闭或来源已被 close 清空则直接结束，不进入普通加载：[ShellTemplateProvider.kt:41](../../../android/lynx-shell/src/main/java/com/example/lynxshell/resource/ShellTemplateProvider.kt#L41)、[ShellTemplateProvider.kt:49](../../../android/lynx-shell/src/main/java/com/example/lynxshell/resource/ShellTemplateProvider.kt#L49)。
- **Call 注册竞态**：[代码事实] 远程 Call 加入 `activeCalls` 后、`execute()` 前再次读取 `closed`；若 close 先发生，当前路径主动 cancel 并失败。若 close 在检查后发生，Call 已在集合中，会被 close 取消。无论哪条路径，既有 `finally` 都会移除集合项：[ShellTemplateProvider.kt:175](../../../android/lynx-shell/src/main/java/com/example/lynxshell/resource/ShellTemplateProvider.kt#L175)。因此“close 先于注册”和“close 晚于注册”两个窗口都闭合。
- **兼容性边界**：[代码事实] URL 不匹配仍不消费预置 bytes；匹配 URL 仍只允许一个 `preparedConsumed.compareAndSet(false, true)` 成功；成功 callback 继续拿到原 ByteArray 实例；首次 claim 后的第二次正常请求仍按旧契约 fallback 到普通 Provider；`close()` 继续释放未消费 bytes、取消已登记 Call并抑制 callback。预置文件路径仍执行 size、空文件、取消、短读和尾部增长检查。
- **确定性测试**：[构建/测试，主流程日志] 新测试通过反射临时替换 private static final executor 为 `GateExecutor`，没有增加生产测试 seam；旧优化版在“提交→close→放行”场景得到 `connectionAttempts=1 / callbacks=0` 的真实 Red，修复后得到 `0 / 0`。另三个可控窗口覆盖 claim 后 close、远程 Call 注册前 close、真实 OkHttp application interceptor 中注册后 close，并检查 `activeCalls` 回到 0：[BundleLoadingOptimizationTest.kt:142](../../../android/app/src/androidTest/java/com/example/lynxshell/sample/BundleLoadingOptimizationTest.kt#L142)、[BundleLoadingOptimizationTest.kt:172](../../../android/app/src/androidTest/java/com/example/lynxshell/sample/BundleLoadingOptimizationTest.kt#L172)、[BundleLoadingOptimizationTest.kt:197](../../../android/app/src/androidTest/java/com/example/lynxshell/sample/BundleLoadingOptimizationTest.kt#L197)、[BundleLoadingOptimizationTest.kt:222](../../../android/app/src/androidTest/java/com/example/lynxshell/sample/BundleLoadingOptimizationTest.kt#L222)。Green 原始回执为 `OK (17 tests)`：[android-tests-queued-close-green.log](android-tests-queued-close-green.log#L1)。本复审未重跑。

## 其余最终 diff 复核

### `ShellTemplateProvider.loadFile()`

- [代码事实] 以已检查长度只分配一个目标数组并直接分块填充；读取前、每个 block 和结束前检查关闭状态；短读或多出尾字节明确拒绝；普通文件、非空与 20 MiB 上限保持：[ShellTemplateProvider.kt:141](../../../android/lynx-shell/src/main/java/com/example/lynxshell/resource/ShellTemplateProvider.kt#L141)。在 App 私有、已由 OTA 校验并由 lease 固定的文件前提下，没有省略内容安全门禁。
- [构建/测试，主流程日志] 最终 17 项设备回归仍保持定长读取、单次 claim、URL 不匹配、close 清源、长度变化、完整 Release 校验和 A/B 旧 lease；本次 ART 3×2 MiB 近似分配为 `6,697,488` bytes。该指标是进程级累计近似值，不是峰值堆、RSS 或 FPS；读取耗时单样本不能用于宣称性能变快。

### `ContentAddressedOtaStore.acquireLease()` / `OtaSidecarDisk.viewResources()`

- [代码事实] 主 Manifest 同次只读一次，但仍核对 manifest ID、release ID 与完整 scope；继续遍历所有主 Bundle 执行 size/SHA `hasUsableObject()`，没有只验证目标 Bundle：[ContentAddressedOtaStore.kt:757](../../../android/lynx-shell/src/main/kotlin/com/ota/android/sdk/ContentAddressedOtaStore.kt#L757)。
- [代码事实] `sidecars.requireAsync()` 仍解析并验证 owner 属于主 Manifest、URL policy、userInfo/fragment、size/SHA 和全部 Async 对象；`viewResources()` 只复用同次已验证的 `AsyncManifest` 做 owner 精确过滤与 SHA 文件映射，没有建立跨调用/跨 App 缓存：[OtaSidecarDisk.kt:133](../../../android/lynx-shell/src/main/kotlin/com/ota/android/sdk/OtaSidecarDisk.kt#L133)、[OtaSidecarDisk.kt:138](../../../android/lynx-shell/src/main/kotlin/com/ota/android/sdk/OtaSidecarDisk.kt#L138)、[OtaSidecarDisk.kt:182](../../../android/lynx-shell/src/main/kotlin/com/ota/android/sdk/OtaSidecarDisk.kt#L182)。
- [代码事实] Bundle 名称仍经过 `validateBundleLookup()`，相同短名歧义继续拒绝；文件路径只从已验证 Manifest SHA 生成。identity snapshot 在读取前取得，完整主/Async 校验后、lease root 登记前复核；整个 acquire 仍在 storage lock 内，外层身份复核仍可关闭失效 lease。
- [代码事实] 显式拒绝 `Ref.EMBEDDED` 与基线等价：旧实现虽先解析 embedded ref，随后的 `resolveBundle()` 对非 downloaded ref 仍返回 null；embedded Bundle 继续走 `EmbeddedBundleRegistry`/Runtime baseline，不经下载态 CAS lease。
- [构建/测试，主流程日志] 最终设备回执继续报告 warm lease 主/Async Manifest OPEN 为 `1/1`，完整主对象、其他 owner Async 损坏拒绝和旧 lease 固定 A/新 lease 固定 B 均通过。

### INFRA 修正

- [代码事实] `android/native-publishing.gradle.kts` 只把 `XMLConstants.ACCESS_EXTERNAL_DTD/SCHEMA` 替换为同值标准 URI 字符串，值仍为空；`disallow-doctype-decl=true` 及其余 POM/.module 校验保持。在已审范围内未发现 XML 外部实体安全边界弱化：[native-publishing.gradle.kts](../../../android/native-publishing.gradle.kts#L58)。

## 剩余验证边界

- [构建/测试，主流程报告] 已有日志记录 queued-close 修复后构建成功、设备 `17/17` 通过；JVM XML 经主流程核对为 `124 total / 121 passed / 0 failed / 3 skipped`，3 项是未配置独立 loopback selectionServer 的既有真实 Server 用例。本复审没有重跑这些命令。
- [待确认] 真实 Rspeedy small/large/Async 新 Host 由另一流程执行；当前本报告只确认其源码会核对 SDK 首屏、fatal、View attach/layout、ready contentDescription 与 Native `caseName/moduleCount/payloadLength/checksum`。在实际 baseline/optimized 回执完成前，不能声称真实页面加载速度、首屏、Async 或内存峰值已经验证。
- [静态推断] 本次修复只闭合新增的预置 source 清空竞态，没有改变共享 cached thread pool 的既有并发策略，也没有把 ART 累计分配误写成峰值内存或用户可感知速度。
