# Android Engine 复用实测报告

这份报告记录当前 Android 受控验证的最终结果。范围是 Lynx SDK `4.1.0`、ReactLynx `0.123.3`，验证对象是 native `LynxViewGroup` Engine cache 与现有 LynxShell 宿主的完整闭环。

结论是：当前 bounded host 路径已经通过功能、native 页面、JVM、构建和严格 Heap 检查。Engine 的借用资格、数据重置、资源解绑、宿主脱离、Group 释放和再次打开都已纳入验收。这个实现把每个真实 Engine 最多借给一个新页面；B 归还后释放 Group，再由 C/D 走新的 Engine 配对。它提供了受控复用能力，适用边界仍由资格键、资源和页面生命周期限制。

## 结果概览

| 验证层 | 结果 | 证据 |
| --- | --- | --- |
| 有界 Engine 复用功能套件 | 11 项 PASS，`55.18s` | [`bounded-host-final-11.log`](evidence/bounded/bounded-host-final-11.log) |
| 真实首页原生路由自动回归 | 1 项 PASS，`6.001s` | [`manual-native-page-instrumentation-2.log`](evidence/bounded/manual-native-page-instrumentation-2.log) |
| 严格 Heap 检查 | 1 项 PASS，`15.105s` | [`bounded-host-helper-fix-heap.log`](evidence/bounded/bounded-host-helper-fix-heap.log) |
| JVM 测试汇总 | 146 total，143 pass，3 external skips，0 fail | evidence/bounded/jvm-summary.json |
| Debug APK / Release AAR | PASS | [`bounded-host-final-build.log`](evidence/bounded/bounded-host-final-build.log) |

官方能力背景：Lynx 官方 release blog 将 `LynxViewGroup` Engine cache 描述为同一 template bundle 在多个 `LynxView` 间重复使用的能力：[Lynx 3.8：Lynx Engine Reuse in LynxViewGroup](https://lynxjs.org/next/blog/lynx-3-8.html)。本报告记录的是在固定版本与当前宿主约束下完成的 bounded 实现与验证，不把它扩展为所有 Lynx 元素、所有页面形态或所有平台的通用缓存承诺。

## 复用模型

```text
冷页 A
  │ 通过真实 SDK 首屏，未失败且满足缓存资格
  │ Engine A 进入 Group idle lease
  ▼
暖页 B
  │ 只能借用一次；创建独立 View、fresh TemplateData、fresh globalProps
  │ 验证 current root、真实文本/几何、计数器和真实 warm frame
  ▼
B destroy
  │ 解绑资源、移除 listener、detach body、清理公开持有者、Group release
  │ enginePointerAfterWarmDestroy = 0
  ▼
新页 C → 新 Engine C
  │ C/D 组成下一次独立 bounded pair
  ▼
新页 D
```

实现中的关键边界：

- 资格 key 同时包含 `appId`、bundle 名称、release、SHA、source、selection、用户身份 epoch、资源 snapshot、URL、屏幕与 preset 尺寸、density、theme、locale 和 fontScale。
- `candidate_trial` 不得捐赠 Engine；必须保留正常 SDK 首屏和业务健康确认。
- bundle SHA、release、identity epoch 和资源身份缺失时直接退出缓存路径。
- 缓存上限是 2 个 idle entry、编码权重 8 MiB、60 秒 TTL；这是宿主缓存的 encoded weight 约束，不是 native Engine 的硬内存上限。
- 每个 Engine 最多借给一个新页面；业务 reload、重复主 load、候选页、未知 native element 或无法证明脱绑的节点不会再次进入 idle cache。
- `list`、`list-item`、`list-container`、`frame`、`Map`、`Video` 等元素的完整脱绑尚未证明，因此不作为已验证的可缓存通用集合。

实现主文件：[LynxTemplateGroupCache.kt](../../android/lynx-shell/src/main/java/com/example/lynxshell/container/LynxTemplateGroupCache.kt#L38)。测试主文件：[BoundedEngineStateTest.kt](../../android/app/src/androidTest/java/com/example/lynxshell/sample/BoundedEngineStateTest.kt#L58)、[BoundedEngineSmokeTest.kt](../../android/app/src/androidTest/java/com/example/lynxshell/sample/BoundedEngineSmokeTest.kt#L1)、[BoundedEngineNativeTabTest.kt](../../android/app/src/androidTest/java/com/example/lynxshell/sample/BoundedEngineNativeTabTest.kt#L1)、[ManualPageEngineReuseTest.kt](../../android/app/src/androidTest/java/com/example/lynxshell/sample/ManualPageEngineReuseTest.kt#L1)。

## 已通过的功能覆盖

最终 bounded host 套件包含 11 项，另有一项真实首页原生路由自动回归闭环，共 12 项功能验证：

| 覆盖项 | 验收事实 |
| --- | --- |
| Small / Large / Async bundle | Small `88,114` bytes；Large `3,234,076` bytes；Async `94,510` bytes，并包含 10 个真实 JS async 场景 |
| A/B 状态重置 | 10 页、5 对 A/B；A 与 B 各自 counter 触控后为 `1`，B 的 marker、globalProps、oldOnly 状态和当前 root 几何均正确 |
| 新 globalProps / 省略字段 | 新页重新构造 TemplateData/globalProps，未复用已消费对象；省略字段场景通过 |
| 当前 root 与 Resolver | 实际 root geometry、Resolver 结果和真实文本相互校验 |
| Lazy bundle | 真实 native fetch，B lazy mount 成功；实际 bundle SHA 前缀 `6a450801...` |
| 资源与 lease | A lease close、B owner/resource 归属和 Group 释放路径通过 |
| concurrent | 同一 Activity 的两个 active View 使用独立 Engine，Native source 精确归各自页面 |
| trim | trim 后 idle lease 被清理，下一次打开使用 fresh Engine |
| cold cancellation | 半初始化 Engine 不得捐赠 |
| business reload / repeat main load | 业务 reload 后退出不得捐赠已重载 Engine；重复主 load 也有同一资格门禁，后者本轮未单独运行 |
| pure static | 不发生业务 mutation 时，warm committed frame 仍完成 |
| real native page | 首页按钮进入 `Native LynxShellActivity`，Back 返回；A/B 共用同一 Engine，C 创建新的 Engine，自动操作真实按钮/Activity/Back，通过 |

状态测试的关键断言也包含真实 UI 触控与当前 root geometry：[BoundedEngineStateTest.kt](../../android/app/src/androidTest/java/com/example/lynxshell/sample/BoundedEngineStateTest.kt#L60)。当前 B 页面截图证据已保存为 `docs/android-engine-reuse/evidence/bounded/state-B-counter1.png`；Lazy 与 native tab 截图分别保存为 `evidence/bounded/lazy-B-mounted.png`、`evidence/bounded/native-tab-B-counter1.png`。

## 关键生命周期处理

对于 reused View，宿主在新 BTS App 启动前创建新的 `TemplateData`，依次执行 `resetData` 和 `reloadTemplate(data, globalProps)`，再重建缓存 UI 的 Android 子 View tree。公开代码位置：[LynxTemplateGroupCache.kt](../../android/lynx-shell/src/main/java/com/example/lynxshell/container/LynxTemplateGroupCache.kt#L163)。

销毁路径会移除内部 listener 和业务 listener，停止 frame observer，解绑资源，销毁 View，运行 detach/attach 清理，移除 Android child views，重建 drawing helper，将 `LynxContext` 的 base context 改为 Application，并清除、UI body、client、client V2 和 list node fetcher。只有满足 detached body、资源解绑成功、首次首屏成功、无 fatal error、无未证明 native element 等条件时，Engine lease 才会回收到 idle pool：[LynxTemplateGroupCache.kt](../../android/lynx-shell/src/main/java/com/example/lynxshell/container/LynxTemplateGroupCache.kt#L174)。

缓存 warm frame 有独立收据：硬件加速路径使用 frame commit callback，其他路径使用 draw cycle。它不会把 SDK cold `onFirstScreen` 冒充成 warm first screen，代码中的 `LynxFirstFrameSource` 对此做了区分：[LynxTemplateGroupCache.kt](../../android/lynx-shell/src/main/java/com/example/lynxshell/container/LynxTemplateGroupCache.kt#L35)。

## 性能与内存：只报告测得的范围

最终 JSON 位于 `/tmp/codex-engine-reuse-20261010/android-group-cache/device-evidence/bounded/files/bounded-engine-smoke-results/grouped/`。bundle 信息如下：

| Bundle | 大小 | SHA-256 |
| --- | ---: | --- |
| Small | 88,114 bytes | `sha256:bd55248f...` |
| Large | 3,234,076 bytes | `sha256:3554ab41...` |
| Async | 94,510 bytes | `sha256:374ddaf3...` |

最新 10 个 Small 样本的完整 `factory → currentRootReady` 数据中，冷页中位数为 `141.724 ms`，复用页中位数为 `192.469 ms`。这个计时包含调度和轮询，并不是 p95，也不是单纯的点击延迟；冷热样本的这组数据不能支持“warm 一定更快”的结论。复用的确定收益是少一次 native Engine 构建和主包再次读取/解析，整体首帧快慢仍应由真实业务以相同呈现口径单独基准。

PSS 观测范围：Ready `196,078–199,766 KiB`，B 退出后 `187,350–196,261 KiB`。数值波动并非单调下降，因此只能作为观察记录，不能当作 native 内存已被精确释放或泄漏已被证明不存在。

## Heap 与宿主回收边界

严格 Heap 项使用 helper fix 后的结果：`15.105s`、0 application leaks、0 library leaks、0 unreachable objects；分析文件为 [`bounded-host-final-heap-analysis.txt`](evidence/bounded/bounded-host-final-heap-analysis.txt)，结果 JSON 为 [`bounded-host-final-heap-results.json`](evidence/bounded/bounded-host-final-heap-results.json)。

验证中还观察到：严格 3 秒 + 3 次 GC 时 idle Engine pointer 仍是非零，旧 host 的弱引用已经可回收；这不是瞬时 native pointer 归零证明，也不是所有 SDK/native 泄漏都已排除。较早的 8 次 GC 检查没有在限定窗口内得到结论，后续 queue drain 后的 HPROF/LeakCanary 结果为 destroyed host 0、application leaks 0。由此只能报告“当前受控场景下 Heap 工具未发现应用泄漏”，不能报告“所有时刻、所有 SDK 对象均无泄漏”。

## 构建与验证证据

- 最终 host instrumentation：[`bounded-host-final-11.log`](evidence/bounded/bounded-host-final-11.log)
- 真实首页原生路由自动回归：[`manual-native-page-instrumentation-2.log`](evidence/bounded/manual-native-page-instrumentation-2.log)
- 严格 Heap：[`bounded-host-helper-fix-heap.log`](evidence/bounded/bounded-host-helper-fix-heap.log)、[`bounded-host-final-heap-analysis.txt`](evidence/bounded/bounded-host-final-heap-analysis.txt)
- 最终 Debug APK / Release AAR 构建：[`bounded-host-final-build.log`](evidence/bounded/bounded-host-final-build.log)
- 原始历史报告：[`TEST_REPORT.md`](TEST_REPORT.md)、[`TEST_REPORT.html`](TEST_REPORT.html)

## 明确保留的限制

本轮只改并验证 Android host bounded path；iOS 与 HarmonyOS 没有改动，也没有声称跨端体验一致。缓存资格不覆盖所有元素和所有页面结构；未证明脱绑的 native element、业务 reload、重复主 load、候选页和未知标签继续走 fresh 或拒绝捐赠。历史诊断中 normal B pixels A、reload B pixels B、C WaitingNative 的结果只作为诊断背景，不被纳入本轮功能验收；readonly-v2 的收集结果也不作为 UI 验收。当前报告不把 `firstScreenSync`、旧 accessibility getter 或私有版本门禁解释成已证实根因。

这份结果证明的是“固定版本、固定宿主、有限资格键和一次性 lease 的受控 Engine reuse 能够通过当前验收”，不是无限缓存、所有组件全面缓存、所有业务路径都能复用，或性能/内存已经在生产口径下完成定量承诺。
