# same Engine 生命周期诊断用例（先冻结）

本目录为新诊断包，不能替代已冻结 `engine-reuse` State/Lazy验收；安全Template套件与产品源码均不改。版本固定 ReactLynx0.123.3、ReactPlugin0.18.3、Rspeedy0.16.3、Lynx4.1。

## 已核实注入方式

当前安装exports没有 `pluginMainThreadCode`，不能猜该API或安装新包。`tools.rspack` 是已有配置入口；ReactPlugin真实生成 `<entryName>__main-thread` 的 EntryDescription（layer=`react:main-thread`，import原entries）。诊断构建只在该实际entry的import末尾追加 `main-thread-observer.js`，保留原imports与layer，故framework先安装Native调用入口，observer在SDK renderPage前安装。构建必须保存实际entry metadata并核对产物存在marker；不改node_modules。

observer仅包装本版本实际global `renderPage/updatePage/updateGlobalProps/rLynxFirstScreenSyncReady/rLynxChange`；若可写则观测真实 `__OnLifecycleEvent`，否则记hook unavailable并以BTS接收firstScreen佐证，不能把没有观测到误当事件没发生。每次调用原样forward this/args/return/exception，只记录入/出、当前MTS initData/globalProps marker与实际patchOptions/isHydration；不reset框架flag，不patch树，不伪造Native事件。

BTS observer在真实entry执行后安装，仅在property descriptor确认可写时包装原 `lynxCoreInject.tt.OnLifecycleEvent`（大小写按runtime实际源码）与 `tt.onAppReload`。实际第一版Android诊断在给 `NativeApp.callLepusMethod` 赋值时发生 `TypeError: no setter for property`，cold React因此没能运行到State effect。修订版保存该方法的实际descriptor并记hook.unavailable，不再替换它；框架patch请求只以MTS `rLynxChange` 实际接收参数观测，不能宣称BTS已拦截所有patch请求。NativeModules仅BTS effect使用。MTS日志用console和自身trace-read函数；BTS直接调用原callLepusMethod读取原始响应，再用真实emitToNative传给宿主，未知callback shape原样保存而不假设成功。这个限制不是被吞掉的异常或虚构成功。

本版本源码 `calledByNative.updatePage` 在 `!isFirstScreenSynced` 才renderMainThread/hydrate；flag模块初始化一次。BTS `tt.OnLifecycleEvent(rLynxFirstScreen)`才hydrate并释放延迟patch。这只是诊断假设依据，不能仅凭静态代码宣称根因已证实。root最新公开ordering控制的B截图真实显示B marker/id、counter0/mount1/旧字段false，但SDK accessibilityLabel getter仍A：旧getter不是像素旧的证据。本诊断同时保存UIText/FlattenUIText公开getOriginText、IUIText.textLayout.text、accessibilityLabel和真实截图；不把单getter当画面真值，也不改冻结安全验收或原型档案。

## 诊断矩阵

| ID | 操作 | 观测与约束 |
| --- | --- | --- |
| D1 | 冷A打开并真实counter0/Native/UI就绪 | 原SDK首屏、originalEngine对象/非零ptr；MTS renderPage/firstSync→BTS firstScreen/hydrate→MTS hydration patch实际顺序 |
| D2 | A真实UI counter按钮点到1 | BTS effect/Native counter1、MTS非hydration patch；建立真实旧UI状态 |
| D3 | A destroy→同官方Group新B，new marker/省略oldOnly | SDK实际相同Engine Java对象和同非零ptr，不是仅同View；新的Context/View；记录MTS updatePage/options与firstSync是否发生、BTS entry/effect/hydrate/patch、真实Native B和实际UI label |
| D4 | B读MTS trace | 原callLepusMethod回执和hook可用性，日志raw保存；不由Native反填生命周期成功 |
| D5 | 对照冷/newGroup | 可另跑只fresh SDK实例，确认observer不会凭空产生firstSync/patch；任何改动后的诊断包不能算冻结State验收通过 |

Android新诊断测试直接使用官方SDK Group cache=true，与安全生产cache隔离；同Group engine身份必须真实匹配。MTS/BTS分别带runtimeId/seq，logcat时间作为跨线程排序；各runtime seq不能当跨线程全序。root采集instrumentation JSON、PID-filtered logcat、实际渲染UIText与截图。Native、origin/layout text、getter及pixels分别报告；任何getter mismatch不能直接命名为pixel mismatch，诊断收集完成也不等于sameEngine目标已验收。

只授权本诊断包构建，输出到独立/tmp目录；不安装依赖、设备或改冻结包。本worker不编译Android，root运行新诊断test。
