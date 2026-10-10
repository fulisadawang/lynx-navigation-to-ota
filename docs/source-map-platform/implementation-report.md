# Provider 身份与 SourceMap 管理实施报告

日期：2026-10-09，2026-10-10 更新。范围：三端原生、Lynx 模板、Contracts、OTA Server 和 Admin。阅读版：[HTML 报告](implementation-report.html)。

## 1. 这次已经做到什么

现在可以把一条 Provider JS 错误关联到**哪个环境、哪个 OTA 宿主、哪个 Lynx App、哪份实际 Bundle、哪次 Release，以及哪个脚本的调试资料**。模板保存同一次生产构建产生的资料；Admin 的每个主 Bundle、Async Bundle 或独立 script 内容行都可以进入 SourceMap 页面，查看源码并粘贴错误栈反解。

本地真实构建与模拟存储链路已贯通。Android / iOS 本地编译通过；Harmony 本轮采集接线完成复核，但 HAR 编译仍被原有基线的 28 个错误阻断。本报告不把编译、模拟定位或历史设备验收当作本轮三端真实错误与线上平台验收。

Async 主线程的调试资料遗漏已补齐：三个 Async 均保存真实编码结果中的调试表，六个主线程与六个后台合成 Provider 定位帧全部 mapped，另六条主线程原始文本格式堆栈也映射成功。六个 Bundle 的实际字节与 SHA 均保持不变。Contracts `0.4.0` 已本地构建打包，**尚未远程发布**；真实云端与设备接入的验证边界仍保留。

## 2. 修改在哪些项目

五个独立 Git worktree 位于同一目录 `/Users/nieyutan/.codex/worktrees/lynx-sourcemap-platform`，分支均为 `codex/lynx-sourcemap-platform`。原有工作区和用户未提交改动保留。

| 项目 | 本轮起点 | 责任 |
| --- | --- | --- |
| `lynx-navigation-to-ota` | `origin/main@b3837d49` | Android / iOS / Harmony Page 与 Native Tab 的 Bundle 身份和错误帧投影 |
| `LynxAppPackagesAndTemplates` | `origin/main@7673d807` | 同次构建资料归档、私有上传登记、接入原发布流程 |
| `LynxContracts` | `origin/test@60114270` | `0.4.0` 的管理 API DTO 和逐帧反解结果 |
| `LynxOtaServer` | `origin/test@9eee86dd` | 独立索引表、受控私有读取、源码 API、加载图校验和反解 |
| `LynxOtaAdmin` | `origin/test@d80c3c7c` | 内容行入口、文件树、只读代码查看器、错误栈反解及准确跳转 |

Server / Admin / Contracts 的 `origin/test` 是新分支的创建起点；本轮没有把 test 分支合并到其他分支。五仓分别通过 PR / MR 交付，具体提交与交付链接以各仓审查页面为准；本轮没有发布包、执行真实数据库迁移或上传 OSS。

## 3. V1、V2、V3 和错误怎么对应

以下身份各有用途，不能互相替代：

| 字段 | 回答的问题 | 来源 |
| --- | --- | --- |
| `env + hostApp + lynxAppId` | 哪个环境、哪个逻辑宿主、哪个业务 App | 本次实际 Runtime 与 prepare / lease / snapshot 的冻结上下文 |
| `releaseId / releaseSequence` | 当前页面来自哪次发布 | 实际交付该页面的发布快照 |
| `sha256` | 当前页面实际运行了哪份字节 | 已校验的实际 Bundle，或直连资源本次读取字节的计算结果 |
| `bundlePath` | 哪个页面主包、哪个加载图 owner | 本次清单的真实主包路径 |
| frame `runtimeRelease / debugKey` | 这一帧应使用哪个脚本的 Map | SDK 逐帧提供的 `debugmetadata:<key>` |
| `buildId / gitCommit` | 调试资料是哪次构建、哪个源码提交产生的 | 模板本次构建归档；不替代实际内容 SHA |

例如 V1 用内容 A，V2 用内容 B，V3 又复用内容 A：错误仍按各自真实 Release 显示发布来源；V1 和 V3 的内容 A 可以复用相同 SourceMap。不会拿最新 V3 的资料去反解 V2 的内容 B。

原生在一次加载开始及字节交付时冻结身份；Provider 分发时不读取全局可变的 OTA current。未知 App、Release 或路径保持 null。直连资源可以计算实际 SHA，但不能凭文件名补造发布身份。同 View reload 无法确认事件属于哪次加载时，保留 View 与帧 key、降低关联精度，不强行关联最新 Bundle。

SDK 只给两个原始定位数字时，三端保留 `positionKind: reported` 和 `reportedFirst / reportedSecond`。Server 找到唯一脚本后再决定按后台行列或主线程函数/PC 解释；主线程依照官方规则先查 `function_id / (pc_index - 1)` 的 bytecode 位置，再查 JS Map。返回源码行列从 1 起算，列按 UTF-16 代码单元表示。

## 4. 构建、上传、查询的完整链路

```text
同一次生产配置 OTA 构建
  → 官方清理前保存每份原始 DebugMetadata
  → 最终磁盘 Bundle SHA / 大小与资料索引核对
  → 私有 OSS 上传、回读确认相同字节
  → Server 按 scope + 实际内容 SHA 登记
  → 继续原有公开 Bundle 上传和 Release 创建/发布

运行时 SDK 错误
  → 三端公共监控 Core 冻结的 Bundle 身份 + SDK 帧 key / 原始位置
  → 既有可替换 Provider（具体外部平台尚未接入）
  → 在 Admin 选中对应内容行，粘贴错误事件或原始栈
  → Server 校验 scope / Release / owner 图
  → 返回逐帧结果，点击已映射帧定位真实源码
```

模板归档放在 `.lynx-symbols/<env>/<appId>/<buildId>/`，不进入公开 OSS、OTA 下载清单或 App 资源。`BUILD_VERSION` 使生产配置构建产生 metadata；本轮没有开启 DEBUG、关闭主线程字节码或升级 Lynx SDK 来规避资料限制。

本次 Tasm `0.0.53` 实际编码已在 `args.debugInfo['main-thread']` 产生 Async 调试表；collector `0.2.1` 原先只识别 root 键，初版因此出现三项 `missing_bytecode_info`。模板在 beforeEmit 保存各输出的真实编码结果，仅在归档副本中按唯一 assetPath 补入 `lepusNG_debug_info`，核对 function_source 与该次 finalEncodeOptions 的主线程 content 相同，并记录真实 `customSections / main-thread`。Server 则使用该脚本自己的 section 文件名，正确关联 Runtime 栈中的 `main-thread` 与 JS Map 的 `main-thread.js`。Bundle Buffer、key 和 Map 没有被改写。

私有对象名固定为 `source-maps/<env小写>/<hostApp>/<lynxAppId>/<内容SHA>/<metadataSHA>.json`。Server 在受控桶回读并校验大小与摘要，不接受任意 URL。登记唯一键为 `env + hostApp + lynxAppId + bundleSha256`；相同语义的资料重跑复用，真正的 Map / artifact / bytecode 冲突返回 409。并发登记由数据库唯一约束保证，不要求修改 OSS 桶的版本控制状态。

Release 入口按真实 `bundlePath / ownerBundlePath` 限定单个主包加载图；同 SHA 多 owner 无法确认时拒绝猜测。Async 帧返回自己的实际 SHA、路径和 owner，点击后读取对应内容的 `fileId`。源码路径只是显示标签，Server 不读取本机文件系统，也不按标签发外部网络请求。

Admin 只读查看器支持文件过滤/折叠/分页、虚拟行渲染、复制、行列高亮。查看脚本和反解的手选脚本分开；手选仅用于没有 debug key 的帧，不能覆盖 SDK 自带的 key。私有对象 key、签名 URL 与存储凭据不传给 Admin。

## 5. 缺失和真实失败怎么显示

| 情况 | 行为 |
| --- | --- |
| 没有登记，或登记后私有对象为 NoSuchKey / NoSuchObject | `200 / not_found`，Admin 正常显示空态 |
| SourceMap 有位置但没有内嵌源码正文 | 可以显示文件位置；正文显示正常空态 |
| 其他实际资料确实缺少主线程 bytecode debug info | 源码仍可浏览；函数/PC 返回 `unresolved / missing_bytecode_info`；本次三个 Async 的资料已完整 |
| 输入非法、作用域或 owner 不匹配、无权限 | 保留真实失败原因，不跨 App 或用最新资料兜底 |
| 存储网络/权限错误、桶配置错误、坏摘要、资料冲突 | 明确失败，可恢复读取提供重试 |

本轮未增加线上错误接收服务、错误数据库、监控 SDK、全局 OTA 发布门禁或老系统兼容层。模板自身的上传/登记失败会停止这次发布流程；管理端查不到资料正常空态，两者职责分开。

## 6. 本地验收结果

| 项目 / 用例 | 结果 | 证据与边界 |
| --- | --- | --- |
| Contracts 类型检查、构建、既有回归、真实 pack | 通过，35 项测试 | `0.4.0` `.tgz` 已用于 Server/Admin 本地安装；不等于远程发布 |
| 模板 SourceMap 回归与类型检查 | 通过，18 项测试 | 临时目录、模拟私有存储与登记函数，包含同次真实 section 调试资料关联 |
| 模板 TEST OTA 生产配置构建 | 通过，3 主包 + 3 Async，共 6 份档案 | REPORT 捕获与最终磁盘 SHA / 资源图覆盖核对通过；sourcesContent 完整 |
| Server 编译与 SourceMap 回归 | 通过，7 项测试 | 包含缺失空态、身份/图校验、Map/bytecode、真实 section Runtime 名称与失败边界 |
| 实际 metadata 上传/登记/查询链路 | 通过，6 首次登记 + 6 重复复用 | 同一上传函数 + 编译后的 Server + 模拟 OSS / 内存数据库 |
| 合成 Provider 定位帧 | 12 / 12 mapped | 六个主线程与六个后台，使用实际编码资料和合成报告位置；非设备崩溃 |
| 主线程原始文本格式堆栈 | 6 / 6 映射成功 | 覆盖三个主包 `main-thread.js` 与三个 Async 真实 `main-thread` 文件名；定位仍是合成输入 |
| Admin Nuxt 类型检查和生产构建 | 最终通过 | 真实 `0.4.0` 包安装；自动脚本选项修正后的类型检查和生产构建均 exit 0 |
| Admin 内置浏览器联调 | 通过 | 3 主包 / 3 Async 入口的 scope、SHA、路径和 owner 正确；157 行真实 TSX 可读；合成 Provider 自动 key 反解到 12:1，点击帧与深链接恢复正确；手定位 120:3 高亮，视图仅 44 行 DOM；资料缺失正常空态、通知为空；Async 资料读取成功 |
| Admin 自动 / 手选脚本最终回归 | 通过 | automatic 和三个脚本可选；无 key 的 Async 后台栈手选 BTS 映射到 ProductDetailPage.tsx:13:1；手选 MTS 但帧有 BTS key 时仍正确映射 13:1；返回 automatic 再次实际 API 反解成功，不发送占位 scriptId |
| Android 监控合同 JVM 回归 | 通过，21 项，0 失败/跳过 | 有针对性的监控合同回归，不能代替真实设备错误 |
| Android App assembleDebug | 通过 | `BUILD SUCCESSFUL`；未安装本轮 APK 做真实错误注入 |
| iOS Debug Simulator 最终增量编译 | 通过 | `BUILD SUCCEEDED`；未进行本轮真实 SDK 错误注入 |
| Harmony 调试 key / 帧选择 helper 断言 | 通过，24 / 24 | 从真实源码提取 helper 与帧选择代码，按 JavaScript 执行；覆盖完整 key、query / fragment、文本边界、换行、长度预算和非法帧不使用顶层 fallback。这不是 ArkTS 编译或设备测试 |
| Harmony 诊断摘要边界断言 | 通过，5 / 5 | 对真实源码提取的普通文本、JSON、超预算 JSON 和诊断调用点执行 JavaScript 断言；结构化 SDK 摘要不经未分类诊断外发，UI 错误回调保留 |
| Harmony HAR 编译 | 未通过：基线 28 错误，本轮仍 28 | `newErrors=[]`；本轮采集接线复核通过，不能宣称 HAR 或设备验证通过 |
| Android / iOS / Lynx / 安全专项复核 | 本轮 P1 / P2 已关闭 | 覆盖最终差异；静态复核不提供 FPS、内存或线上无故障证明 |
| 真实 OSS、数据库迁移、Provider 外部平台、三端真机错误 | 未执行 | 本轮授权范围为必要回归和本地编译 |

本地证据：

- [实际构建符号链路结果](../../../.workflow/implementation-20261009/artifacts/real-symbols-result.json)
- [Admin 浏览器结果](../../../.workflow/implementation-20261009/artifacts/admin-browser-result.json)、[源码查看截图](../../../.workflow/implementation-20261009/artifacts/admin-source-view.jpg)、[正常空态截图](../../../.workflow/implementation-20261009/artifacts/admin-source-empty.jpg)。截图的 120:3 是手动定位；12:1 反解使用合成 Provider 输入，不是实际设备崩溃。
- [Harmony 最新基线与本轮错误比较](../../../.workflow/implementation-20261009/artifacts/harmony-final-baseline-comparison.json)、[Harmony key / 帧选择 helper 断言](../../../.workflow/implementation-20261009/artifacts/harmony-key-regression.json)
- [Harmony 诊断摘要边界断言](../../../.workflow/implementation-20261009/artifacts/harmony-diagnostic-message-regression.json)
- [模板构建](../../../.workflow/implementation-20261009/results/template-build.log)、[模板回归](../../../.workflow/implementation-20261009/results/template-source-map-tests.log)、[模板类型检查](../../../.workflow/implementation-20261009/results/template-typecheck.log)
- [Server 回归](../../../.workflow/implementation-20261009/artifacts/server-source-map-tests.log)、[Admin 最终类型检查](../../../.workflow/implementation-20261009/artifacts/admin-typecheck-final.log)、[Admin 最终生产构建](../../../.workflow/implementation-20261009/artifacts/admin-build-final.log)
- [Android App 编译](../../../.workflow/implementation-20261009/artifacts/android-app-build.log)、[iOS 最终编译](../../../.workflow/implementation-20261009/artifacts/ios-build-final.log)、[Harmony 最新编译](../../../.workflow/implementation-20261009/artifacts/harmony-build-final.log)

这些是分组 worktree 内的本地证据；单独发布某个仓库时不会自动携带其他仓库和本地构建日志。

Async 主线程最新结果：

| Async 内容 | 真实函数表 | 反解到源码 | 结果 |
| --- | --- | --- | --- |
| Campaign | 39 个函数 | `src/components/store/CampaignPage.tsx:14:1` | Provider reported 帧与文本格式堆栈均成功 |
| ProductDetail | 26 个函数 | `src/components/store/ProductDetailPage.tsx:13:1` | Provider reported 帧与文本格式堆栈均成功 |
| Reviews | 26 个函数 | `src/components/store/ReviewsPage.tsx:13:1` | Provider reported 帧与文本格式堆栈均成功 |

补齐证据：[编码结果与字节不变证明](../../../.workflow/implementation-20261009/async-mts-completion/encoding-proof.json)、[完整联验记录](../../../.workflow/implementation-20261009/async-mts-completion/integration.log)、[模板最新构建](../../../.workflow/implementation-20261009/async-mts-completion/template-build.log)、[模板 18 项回归](../../../.workflow/implementation-20261009/async-mts-completion/template-tests.log)、[模板类型检查](../../../.workflow/implementation-20261009/async-mts-completion/template-typecheck.log)、[Server 最新构建](../../../.workflow/implementation-20261009/async-mts-completion/server-build.log)、[Server 7 项回归](../../../.workflow/implementation-20261009/async-mts-completion/server-tests.log)。最新最终归档为模板 `.lynx-symbols/test/10020000/2d4973a6-0210-47f2-ae72-da048224640d/index.json`；编码不变证明和联验均对应这份最终归档，六个 Bundle 字节保持不变。

## 7. 正式启用的顺序

1. 经授权正式发布 Contracts `0.4.0`，核对 Server/Admin 固定版本与锁文件的包内容。若发布内容与本轮 tarball 不同，重新生成并验证锁文件。
2. 部署具备新 API 的 Server：生成 Prisma Client，经授权执行 `20261009000000_source_maps` 索引表迁移，配置私有桶读取身份。
3. 部署 Admin 查看页；为模板 CI 配置同一私有桶的读写身份和对应登记 API。TEST CI 仅精确允许登记 POST，不允许读取源码或反解；人工/PROD 沿用明确的管理权限。
4. 在需要正式上线验证时，执行真实云端上传和三端实际错误样本验证，再将 Provider 接到选定的外部监控平台。本轮没有自动执行这些外部动作。

所需私有配置名称为 `SOURCE_MAP_OSS_BUCKET / SOURCE_MAP_OSS_REGION / SOURCE_MAP_OSS_ACCESS_KEY_ID / SOURCE_MAP_OSS_ACCESS_KEY_SECRET`，STS 可加 `SOURCE_MAP_OSS_SECURITY_TOKEN`；配置值通过环境变量或 CI 变量提供，不写进源码、日志或报告。

各仓详细说明：模板 `templates/lynx-template/docs/SOURCE_MAP_RELEASE.md`；Server `docs/source-maps.md`；Admin `docs/source-map.md`；原生 [运行时合同](../lynx-view-monitoring-v1/runtime-contract.md)。先前临时设计中若仍有全局发布门禁、OSS 版本控制 Disabled、旧 DTO 或其他与本轮不符的要求，**以本实施报告及实际冻结合同为准**。


## 8. 桌面排查界面与上传路径修订

按本轮反馈，SourceMap 页面改为桌面工作区：左侧文件树、右侧源码、底部错误结果；默认打开业务源文件，依赖收起，构建 SHA / Git 信息按需展开。反解自动定位首个可用帧，跨 Async 点击保留同次结果。没有新增移动端适配。

新归档将 source 标签规范为 `src/...`、`packages/...`、`node_modules/...`，构建根路径记为 `.`；保留源索引和同名区分。路径规范化阶段逐项核对了 6 个 Bundle 字节/SHA、SDK key、mappings、源码正文与已有 bytecode，15 项阶段回归及模板与 Admin 类型检查/构建通过。随后 Async 主线程资料补齐的最新验证为 18 项模板回归、12 / 12 合成定位和 6 / 6 主线程文本格式堆栈成功；此前初版 9 / 3 结果已替代。

[桌面修订验证](../../../.workflow/implementation-20261009/ui-refinement/verification.json) · [路径规范化逐项证据](../../../.workflow/implementation-20261009/results/template-path-normalization-proof.json)

![桌面SourceMap界面；两帧为合成Provider定位样本](../../../.workflow/implementation-20261009/ui-refinement/desktop.jpg)
