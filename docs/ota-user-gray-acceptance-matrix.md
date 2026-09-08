# OTA 用户灰度、原生构建号与三端请求：最终验收索引

日期：2026-09-06。分支：`codex/ota-user-gray-versioncode`，三个仓库均为未提交工作树。本文件是原计划 S01–S28 / C01–C22 的证据索引，不把每条计划都写成设备通过。

## 结论与范围

本地实现及用户调整后的验收范围完成。用户取消 Android/Harmony **模拟器**测试，两端按非设备测试与构建收口；真机本轮未验收。iOS 保留已完成的真实模拟器结果。没有远程部署、远程数据库迁移、npm 发布、Git 提交或推送。

| 层级 | 本轮结果 | 可复核证据 |
|---|---|---|
| Contracts | typecheck/build + 34/34 测试 | 独立 LynxContracts；本地 pack 产物供 Server 联编 |
| Server | TypeScript + 125/125，0 失败/跳过 | 本地真实 Server HTTP、独立连接的本地 MySQL 事务/并发测试；不是远程服务验收 |
| 历史序号预览 | 44 scopes / 372 本地记录 | 只读 SELECT；`readOnly=true`、`applied=false`，未对远程数据执行 |
| iOS | SDK 83/83；版本解析 9 项；模拟器 4/4 | [iOS HTML](ios-ota-user-gray-test-report.html)：19 张场景截图、4 个隔离 Store、401 个 CAS 对象重新 SHA 验证 |
| Android | JUnit 87/87，13 suites；APK 构建成功 | [Android HTML](android-ota-user-gray-test-report.html)：其中 3 项真实 Server JVM 测试、14 个阶段；不算设备 UI 通过 |
| Harmony | 宿主 18/18 + Core 25/25；HAR/App 构建成功 | [Harmony HTML](harmony-ota-user-gray-test-report.html)：5 项真实 Server HTTP；ArkTS 经宿主适配，不等于 Harmony 原生 IO 或设备渲染证明 |
| 内置下载 CLI | 12/12，包括真实 Server 100 包 | `android/app/scripts/sync_ota_bundles_to_assets.test.mjs`；三端共享协议，只在临时目录写测试输出 |
| 静态检查 | Android+iOS 111 PASS；Harmony 90 PASS | 均为 0 WARN / 0 FAIL，不替代运行验收 |

三份 HTML 的筛选、展开/收起已在 Codex 浏览器实际检查，iOS 截图弹层也已检查。Harmony unsigned App 未签名、安装或运行。Android 早期 driver 在 XML 解析处中止，原失败保留；离线解析修复的 23 项测试不等于设备重跑成功。

## Server 矩阵定位

路径相对独立 LynxOtaServer 仓库。

| 原计划编号 | 内容 | 实际证据 |
|---|---|---|
| S01–S12、S14–S28 | 全量/灰度竞争、禁用/解绑、全量化、兼容过滤、参数拒绝、回滚/内置指令、Harmony、ETag、旧协议 | `src/modules/policy/latest-selection-http.test.ts` 的用例名称携带 S 编号；纳入 125 项全量运行 |
| S13 | 发布/规则变化的原子性、revision、并发与一致快照 | `src/storage/selection-coordinator.test.ts`、`src/storage/prisma-selection-coordinator.test.ts`：独立 MySQL 连接，不依靠仅内存锁证明数据库安全 |
| 迁移与版本顺序 | 稳定历史排序、BigInt、scope 计数器 | Prisma 测试和两份 migration；`scripts/backfill-release-sequences.mjs` 另提供只读映射预览 |
| 公共包联编 | 不误用已安装的旧 npm 包 | `scripts/verify-local-contracts.mjs` 实际执行本地 `npm pack`，在临时目录解包、联编和测试；不替换共享 node_modules |

## 客户端矩阵定位

SDK 测试入口：iOS `ios/OtaIOSSDK/Tests/OtaIOSSDKTests/OtaUserSelectionTests.swift`；Android `android/lynx-shell/src/test/kotlin/com/ota/android/sdk/OtaUserSelectionTest.kt`；Harmony `scripts/ota-user-gray/harmony-host-tests.mjs` 与 `harmony-core-tests.cjs`。逐项名字及结果在各端 HTML 内。

| 编号 | 内容 | 已有证据与边界 |
|---|---|---|
| C01 | install 前注册 | 三端 Router pending identity 实现与编译；iOS 启动请求场景。Android/Harmony 全 App 启动时序未设备验收 |
| C02 | 同用户重复注册 | identity box / gate 幂等测试；iOS 场景断言。Android/Harmony 不宣称 UI 实例实测 |
| C03 | 登录绕过 30 分钟 | identity epoch 清门控、同步测试；Android 另有 5 项 PageRefreshGate 单测 |
| C04 | A→B / 匿名 | 三端 SDK/真实 HTTP 身份隔离；iOS 有真实容器显示证据 |
| C05 | 换账号且离线 | SDK 覆盖 embedded / 无 embedded 分支；不声称 Android/Harmony 飞行模式设备验证 |
| C06 | 延迟 A 返回晚于 B | 三端 SDK/本地真实 Server 暂停响应后释放；A 不提交 B State |
| C07 | candidate 迟到回调 | iOS/Android expected identity、release 和首屏保护测试；Harmony 无 candidate，记为不适用 |
| C08 | 同 releaseId 灰度转全量 | 三端真实 HTTP 及 State 元数据测试；相同 bytes 不重下 |
| C09 | 活体 lease 与 GC | SDK Store lease 测试；Harmony 使用 Node FS 适配，非系统 IO 认证 |
| C10 | previous 属于旧用户 | 三端选择与回滚行为测试，不允许 B 使用 A 灰度 |
| C11 | 冷读 gray / unknown | 三端 Store 新实例读取与重新确认测试；unknown 不冒充 full |
| C12 | Tab 切换不联网、后台不替换活实例 | iOS UITest 实例/请求计数；Android/Harmony 对应容器已实现、编译，设备运行未验收 |
| C13 | 主动刷新重载 Tab | iOS UITest；三端均处理部分成功后重读已提交 State。Android/Harmony 设备 UI 未验收 |
| C14 | 100 包仅 050 更新 | iOS 模拟器与 SDK，Android JVM、Harmony 宿主真实 HTTP：仅下载缺失对象，复用其余 CAS |
| C15 | 跨用户复用 bytes，不复用决定 | 三端 SDK/真实 HTTP 覆盖复用与选择归属 |
| C16 | 内置指令及旧修订 | 三端持久化指令、旧响应拒绝；iOS 另有重新启动场景 |
| C17 | 所有 OTA 入口参数一致 | API 单测、真实 HTTP 记录及统一 captured context 链；本地命中不增加网络请求 |
| C18 | Android 原生构建号 | APK 实际 code=1、name=1.0.0-debug；初次设备请求确为 code=1；不是计划举例 code=120 的设备证据 |
| C19 | iOS 构建号与非法值 | 模拟器默认 CFBundleVersion=1；非法 1.2.3 覆盖进入同一规范化校验并保留 embedded。未另打 CFBundleVersion=800/1.2.3 的 App |
| C20 | Harmony 自身平台/构建号 | 实际 bundleManager 调用已 ArkTS 编译；宿主 HTTP 发 harmony、精确构建号，无 Android 重试。未声称原生安装 code=25 验收 |
| C21 | 宿主/SDK 更新后旧 State | 三端兼容范围重新判断测试；不沿用不适用选择 |
| C22 | 内置 baseline CLI | 12 项测试：必填目标 versioncode/SDK、匿名、仅兼容 full；没有个人灰度被写入正式内置资源 |

## 已落地的行为

请求继续使用 `GET /api/ota/v1/releases/latest-bundle-list`，新增精确 `userId`、`versioncode`、`lynxSdkVersion`，平台支持 `harmony`。新上下文必须完整，userId 可省略以匿名查询。Router 提供 `registerOtaUserId` / `clearOtaUserId`。

灰度资格不能绕过版本兼容：兼容的全量 V7 覆盖灰度 V6。Bundle 顺序用不可变 `releaseSequence`，选择修订用 `policyRevision`，所以显式 V10→V5 回滚仍可正确接受。Manifest 完整、CAS 增量、embedded 不复制、普通 Tab 切换不发请求均保留。历史已被 GC 的对象回滚时可能需要重新下载，不能声称永久保存所有版本。

## 复核和交付边界

```sh
node scripts/ota-user-gray/verify-delivery.mjs
```

这是只读证据一致性检查：报告计数、实际 APK/HAR/App SHA、iOS/Harmony 被测源码 SHA、保护文件 SHA、本地报告资源与未验收标记。它不重跑测试，不证明远程上线，也不将 Android/Harmony 升级为设备通过。

真正上线还需要另行授权：发布新版 Contracts、固定 Server 对应依赖版本、远程迁移/部署，然后联调真实环境。本轮没有执行这些外部变更。Android/Harmony 设备 UI、Harmony 原生文件系统/线程与资源行为留为后续专项；不能用本轮 43 项宿主测试代替。
