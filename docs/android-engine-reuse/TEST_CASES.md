# Android TemplateBundle Group 安全缓存测试

2026-10-10 先冻结新合同，再切换活动测试。Runtime仍为Lynx4.1.0/PrimJS4.1.1，真实Fixture/Store/Factory/Native/UI断言保留。

## 原 Engine 缓存原型结果

`grouped-instrumentation-4.log`：4项中2 PASS / 2 FAIL / 0 ERROR。真实Engine身份与并发两项通过；State与真正Lazy两项失败。B的Native数据已经是新marker/pageId、oldOnly=false、counter0/mount1，但UI READY仍是A；State UI保留counter1。原目标因此被真实UI一致性阻断，不改写为通过。

完整原型等字节归档到 `prototype-tests/LynxEngineGroupReuseTest.kt`（SHA256 b91d954ff69d64cc45331611aec677b6b90fed41496c1b2b5b86f150851a5c1e）与 `prototype-tests/EngineStateReuseTest.kt`（6720f8118a0ca3065c4344e39d117925d5356be22e55094cc9e4f16cea14458b），不属于Android test source。原型含后续五项未运行扩展，grouped4证据仅覆盖实际运行的四项。

## 安全方案冻结判据

- Group设置setEnableCacheEngine(false)，只复用parsed TemplateBundle：相同真实Java对象、相同非零nativeTplPtr；同SHA或统计命中不足。
- 每页新的View/Context、不同非零nativeShellPtr，renderer.mLynxEngineRef=null，没有旧Engine/UI/VM缓存。
- 每页真实SDK.onFirstScreen、Native正确payload/exact source、UI READY/layout；删除全部cachedFrame callback/enum。
- LynxTemplateGroupCache.isReused仅代表Group/Template命中，不代表EngineHit；继续核对真实parsed对象/pointer。
- trim/evict/retire通过SDK group.release使TemplateBundle nativePtr归零；每页正常SDK destroy。
- 原State Native与UI A→B省略旧字段、counter0、mount1断言和真Lazy字节/SHA/source断言保持。

## 活动测试矩阵

| 场景 | 必须观察 | 活动测试 |
| --- | --- | --- |
| Small/Large/Async顺序重开 | 同parsedTemplate/非零tplPtr，freshShell不同，无cachedEngine，每页SDK首屏+真实Native/UI | LynxTemplateGroupReuseTest |
| 跨Activity同key并发 | 各freshShell/无cachedEngine，第一页仍存活，两source正确 | 同类 |
| 同Activity双View | 两exact source，freshShell独立，不能用独立Activity替代 | 同类 |
| READY→destroy留idle→trim10→B | trim前真实tplPtr保留，后tplPtr0，B新parsedTemplate正常 | 同类 |
| 十次Small往返 | Template复用/freshShell，每次SDK首屏/READY；PSS/Java used仅诊断 | 同类 |
| 冷A首屏前立即取消→B | 半初始化Group/Template不能借，B独立真实成功 | 同类 |
| secondaryHost WeakRef | 辅助函数返回仅WeakHost/数字/Template，删除Page map后有界GC | 同类诊断 |
| State A oldOnly+真实UI counter1→B省略字段 | B Native/UI新marker/pageId，hasOwn=false/counter0/mount1，同Template但freshShell/Context | TemplateGroupStateTest |
| 真Lazy A未点→B首次点 | Store kind=BUNDLE，Native fetch0→1，原delegate binarySHA/size、B组件payload/UI | 同类 |

EngineGroupPoolTest原15项仍测试通用slot ownership/key/并发/invalidate/LRU/count/encodedBytes/TTL/close/create，不证明EngineCache启用。encodedBytes只是模板成本，不是nativeRAM。

## 运行与证据边界

旧固定Fixture Small88114/Large3234076/Async94510 bytes+原SHA和10JS，描述 `files/bundle-loading-fixture.json`；State/Lazy描述 `files/engine-reuse-fixture.json`，App10030072/r20261010_001/本机18782及真正lazy-bundle/EngineReuseLazyPanel.lynx.bundle。UI通过公开LynxBaseUI屏幕geometry+MotionEvent，不改flatten、不注入JS。

结果 `files/template-group-cache-results/<runLabel>/<testMethod>/results.json`；label仅归档目录。Native实际source/payload/accepted即时保存，SDK时间单独记录。WeakHost至多8次GC，明确gcResultConclusiveForNoLeak=false；十次PSS无主动GC/增长阈值，不声明无泄漏或性能达标。

测试worker未编译、安装、执行设备或修改产品；安全源码完成不等于已通过。原型失败目标和安全Template缓存目标分别报告。
