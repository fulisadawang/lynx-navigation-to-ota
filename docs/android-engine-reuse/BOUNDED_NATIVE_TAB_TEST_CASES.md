# Native Tab 有界 Engine 复用：先行测试

2026-10-10。独立新增 `BoundedEngineNativeTabTest.kt`；不改冻结 State/Lazy 字节、安全九项、已完成的 Bounded State 测试或生产实现。

| 步骤 | 输入与实际操作 | 必须观察的结果 |
| --- | --- | --- |
| 准备 | 读取既有 engine-reuse-fixture.json；真实 Store reserve/stage/install | Frozen State 的 Manifest SHA/size 匹配；不自造模板字节 |
| 冷 A | MainActivity/AppCompat 的 FrameLayout 中 add LynxTabFragment，commitNow | 真正 Fragment loader/Factory/render；当前 Root READY A、counter0/mount1、旧字段存在；debug error=ready；真实 Engine 非零 |
| A 交互 | 当前 Root 按钮，真实 MotionEvent 点击 | counter1、exact Native source=A；不能只看回执而不核当前 Root 文本 |
| A 销毁 | remove A，commitNow | Fragment 的 onDestroyView 关闭真实 Store lease；Engine 非零进入一次可借状态 |
| 暖 B | 新 Fragment，同模板、marker B，省略旧字段；add/commitNow | original Engine Java 对象及同非零 nativePtr；新 View/Context；当前 Root 唯一 READY B、counter0/mount1/旧字段false；debug error=ready表示真实Tab健康首帧消费完成 |
| B 交互 | 当前 Root 按钮，真实 MotionEvent 点击 | counter1及exact Native B source；不能复用A的Native owner |
| B 销毁 | remove B，commitNow | B Store lease关闭，Group释放后原Engine nativePtr归零 |
| 清理 | finally移除仍added的Fragment、还原scoped runtime并trim | 原 installedActivityBundleRuntime 引用恢复；测试缓存及lease收束 |

真实 Tab pageID 由生产 `onCreate` 算法 `lynx-tab-${spec.tabId}-${System.identityHashCode(fragment)}` 生成。测试在 newInstance 后、commit 前用该同一算法设置实际 `lynx.tab.global.props` argument 的 probePageId；同时核对 Fragment host tag 与 Native source，不通过私有 callback 或伪造Native事件生成成功。

测试 Runtime adapter 只将真实 `acquireCurrentBundleLease` 包装成 PreparedActivityBundle（file、release/SHA、source=ota_current、epoch=0、sidecars及releaseLease），resolvePage/resolveCurrent 均只读真实 Store。prepare 不属于本用例，调用即失败。该adapter用于隔离 Native Fragment 生命周期和Engine接线，不能作为 selectionServer、用户灰度或候选版本选择验收。

READY 读取当前 RootUI children 中唯一ID的 `IUIText.textLayout.text`；不使用SDK全holder ID查询的旧orphan metadata。debugStateDescription只读真实Tab状态：cold通过SDK首屏，warm生产分支通过onCachedFrame消费健康收据。本测试不直接接触该privatecallback，不伪造SDK.onFirstScreen，也不把观测时间称为实际frame提交时间。

仅源码冻结/静态核对，不执行构建、安装或设备。本用例实际运行通过之前，报告不得宣称Native Tab已通过。
