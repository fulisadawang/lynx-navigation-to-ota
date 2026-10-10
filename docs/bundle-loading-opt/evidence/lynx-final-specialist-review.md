# 最终 Lynx Change 只读复核

结论：已审最终diff无阻断finding；实现正确性与线程边界通过静态复核，整体首屏提速及“90分”目标仍证据不足。本轮不写产品/测试代码、不构建、不执行测试、不操作设备，仅读取源码及已归档TEST_REPORT。

Checkout `/Users/nieyutan/.codex/worktrees/bundle-loading-opt/lynx-navigation-to-ota`，相对`b3837d491069dd5409d78dad75276201c54edaa3`。当前改动为Android/iOS，Harmony按最新用户要求暂缓，没有Harmony产品或设备验收。Fixture实际锁定ReactLynx0.123.3/Rspeedy0.16.3/React plugin0.18.3，Native Lynx4.1.0/PrimJS4.1.1；没有从源码存在推断跨端运行一致。

## 已审事实

1. Android Provider：`ShellTemplateProvider.kt:45-67`将稳定`hasPreparedSource`身份与可清空的volatile字节源分开，队列中任务先检查closed、只有CAS一次claim，清源后不会将关闭任务误当作未准备而联网fallback；close清源，Network Call登记后复核closed。`140-160`定长ByteArray读取保留普通文件/大小/非空、短读/增长和取消检查，没有绕过SDK对象验证。全量数组拷贝减少属于宿主Reader，不证明JNI/Lynx零拷贝或完整App峰值改善。

2. Android Store/Sidecar：`ContentAddressedOtaStore.kt:762-785`同次lease复用一份main记录和已校验Async Manifest，但仍检查完整Release所有主对象，requireAsync全部owner与对象，scope和身份末端复核后登记主/sidecar lease；`OtaSidecarDisk.kt:138-149`仅从当前已验证的manifest派生当前owner资源视图。不是跨Release全局parsed缓存，没有省掉SHA或改GC/并发池策略。

3. iOS固定索引：`OtaAsyncBundleStore.swift:11-32`使用URL alias和规范化requestKey命中结果的Set union，零/多匹配拒绝；byte与path共用matcher。`93-115`准备时verify/decode/validate完整清单，筛owner后构建不可变索引，字节消费仍verifiedData目标size/SHA。`OtaSDK.swift:166-178`闭包捕获页索引，不重新读取可变current。`OtaSidecarRetention.swift:136-145/156-212`保留closed、activeResolves、drain后放lease，不把Map或bytes作无期限缓存，也不声称close立即释放索引引用。

4. iOS线程：`LynxShell.swift:450-480`Tab主包读取在Task.detached前后均检查取消，数据回传后仍MainActor generation和身份epoch门禁，UI创建/加载在原边界；pending Resources/lease的defer保留。detached系统文件读取本身不等于可立即中止，报告已限定未单独gate该窗口。普通Page只有DEBUG观察点。`LynxBundleLoadDiagnostics.swift`全文件DEBUG、record锁外调用sink，不进入生产新ABI，不能当成首屏加速证明。

5. 真实Fixture：`scripts/fixtures/bundle-loading/src/FixturePage.tsx:25-47`只在background effect/handler执行计算、更新状态并NativeModules回执；runSmall/runLarge/runAsync均标background only。生成payload及十计算模块有background-only模块边界。`build-fixtures.mjs:88-99`排除__main-thread拆包，其余小/大主包明确内联；生成实际计算模块，不在bundle末尾填padding。页面UI只Lynx元素；Native回执状态与SDK首屏分别计数，非零reply显示真实FAILED。标签表示计算结果，不是伪造render完成。

## 前置假设重新核验

- iOS manifest删除/损坏后旧prepared页可读、新prepare拒绝损坏；目标对象SHA仍核验，这是固定解析快照的行为合同，并非parser调用次数承诺。
- iOS重复URL/URL-path union歧义已由测试取得Red并修复matcher；最终path没有走旧覆盖字典的捷径。
- Android queued-close因清源误fallback风险已由最终hasPreparedSource/closed边界修复；没有将成功字段置空来代替真实加载。
- iOS页索引新增metadata与准备validate仍有成本，不能默认全部冷/热场景加速。

## 执行证据边界

读取`docs/bundle-loading-opt/TEST_REPORT.md`及iOS索引测试源码；本轮未复跑。报告列Android新增17/17设备回归、JVM121pass/3skip，iOS Core107；真实相同SHA small/large/十外部脚本在Android/iOS模拟器满足SDK首屏、UI与Nativepayload门禁。既有iOS完整NativeReadiness仍因不相关测试不能编译，新增benchmark采用明确排除范围，未冒称完整宿主套件通过。

Android Reader累计近似ART分配改善不能改写成OS峰值内存改善。Android正式首屏仅每版单样本且有变慢case；iOSn=10 nearest-rank p95即最大样本，尾部仍偏高且配对复测未证明整体首屏改善。报告这些限制准确，不能称已经加载提速/达到90分。未测三端一致、真机、十页并存/返回footprint或JNI实际copy份数。

本次没有重大剩余源码修改建议。测试/构建配套（publishing JAXP、Xcode注册、Podlock）超出本次Lynx产品加载链深审范围，以主Agent和平台审查结论为准。
