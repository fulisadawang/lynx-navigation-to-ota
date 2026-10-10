# Android 有界 Engine 复用 smoke：先行用例

日期：2026-10-10。此文档覆盖生产 `LynxTemplateGroupCache` 的一次 Engine 借用候选；固定
`BundleLoadSmall`、`BundleLoadLarge`、`BundleLoadAsync + 10 个外部 JS` 的既有字节、清单和 SHA
不得修改。结果文件固定写入应用私有目录
`bounded-engine-smoke-results/grouped/<test-name>/`。

Heap 诊断补充先行用例：首个 dump 若旧 Activity 被 Android 延迟队列保留，在同一个 idle Engine 仍存活时等待三秒并进行诊断 GC，采第二个 dump；记录真实 Engine ptr 仍非零，再分别按全部强根分析。不能先清池、再用清池后的 Activity 释放宣称 idle 缓存安全。

2026-10-10 已证实 idle Group → UIOwner.context → ListNodeInfoFetcher.renderer → Activity 的强根。修复回归在第二次诊断 GC 后严格要求旧 Activity 弱引用已清空，且同一个 idle Engine ptr 仍非零；这是先行失败用例，不能因两个空闲槽而放宽。

## 不变的验收原则

- 冷页 A 的 `onFirstScreen` 是 SDK 冷首屏；复用页 B 只能以真实 draw/commit 的
  `onCachedFrame` 收据完成，不能合成或冒充 SDK `onFirstScreen`。
- UI 不能用 `findUIByIdSelector` 作为真值：SDK 查询可能返回已经脱离当前根树的旧节点。
  验收从当前 `rootUI` 递归寻找 `bundle-bench-ready`，要求唯一、已布局且 READY 文本等于
  fixture 元数据。
- 每页 Native 回执必须来自本页精确 `pageId`，并校验 fixture、case、模块数量、数据长度和
  checksum；Async case 必须仍为十个脚本真实执行的既有结果。
- Engine 只允许 A→B 一次复用：A 与 B 必须是同一 Java Engine、同一非零 native pointer，
  但为不同 `LynxView`、`LynxContext`、native render shell。B 销毁后 Engine pointer 必须为 0；
  随后的 C 必须是新 Engine。不得以 native pointer 地址被分配器复用判断 Java Engine 是否相同。
- “WeakReference 在有限次 GC 后为空”只是诊断记录，不能推导为无泄漏；可选 HPROF 只在
  `captureHeap=true` 时落盘。

## 可执行用例

| ID | 用例 | 通过条件 |
| --- | --- | --- |
| BE-S01 | Small、Large、Async 各 A→B→C→D | A/B 同 Engine + 同非零 pointer；B/D 是当前根树 READY 和新 Native source；C 不同于 A 的 Engine；B/D 销毁后其 Engine pointer 为 0；冷页 SDK 首屏与暖页 cached-frame 收据分别存在。 |
| BE-S02 | 同一 Activity 两个同时活着的页 | 两页都取到各自精确 Native source 和当前根树 READY；两页 Engine 不同，创建第二页不改变第一页 Engine/pointer/READY。 |
| BE-S03 | trim idle 与下一页 | A 销毁后的 idle Engine pointer 非零；`onTrimMemory(10)` 后为 0；下一页为新 Java Engine 且正常 READY。 |
| BE-S04 | 冷页首帧前取消 | A 尚未到达真实首帧即销毁；下一页正常 READY 且不是 A 的半初始化 Engine，取消页不接受迟到 Native 回执。 |
| BE-S05 | 十页、五对与内存观察 | 五组 A→B，各组同 Engine；组与组之间 Java Engine 不同；每页记录 PSS/Java heap、A/B engine identity/pointer、B 释放后的 pointer。数据只作趋势观察，无内存阈值和无泄漏结论。 |
| BE-S06 | 旧 Host 弱引用/可选 HPROF | 独立 Activity 的页归还 idle 后记录 bounded GC 与可选 HPROF；持续保留 idle Group，避免先清池伪造 Host 释放。 |
| BE-S07 | 冷页业务 reload 不可捐出 | 冷 A 真正 `reloadTemplate` 并接到 SDK `onPageUpdate` 后退出，B 必须为新的 Java Engine；随后新的冷 A2 未 business reload 时，B2 必须再次命中同 Engine 的一次复用。 |
| BE-S08 | 独立静态 Bundle 的 warm frame | 新建、单独构建的 `EngineReuseStaticProbe` 只用 `useInitData`、`useGlobalProps` 和 `root.render` 输出 READY 文本；源码及构建前检查均禁止 `useEffect`、`useState`、Native 调用和定时器。A 冷页的 SDK 首屏后，B 必须由 Factory 的公开 `resetData → reloadTemplate → rebuildViewTree → renderTemplateUrl` 路径显示 B 的当前 Root 文本，同时得到一次 typed cached-frame 收据；测试本身不注入业务状态更新。 |

BE-S08 的 Bundle 与 Small/Large/Async、State/Lazy 的固定输入完全分离；它只证明静态页的
SDK 生命周期与实际当前 Root 结果，不替代真实 lazy 独立 Bundle、完整泄漏或性能 p95 验收。
