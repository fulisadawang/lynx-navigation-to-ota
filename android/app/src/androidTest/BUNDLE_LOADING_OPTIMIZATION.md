# Bundle 加载优化 Android 可执行测试

本轮先写测试，记录基线结果，再修改 Provider 与 Store。用例入口为 `com.example.lynxshell.sample.BundleLoadingOptimizationTest`，沿用仓库已有 `android.test.InstrumentationTestRunner`，只安装到 `com.hugboga.custom.otae2e` 隔离 App。

INFRA 修正：原 `android/native-publishing.gradle.kts` 在声明工具链上先于测试源码报 `XMLConstants.ACCESS_EXTERNAL_DTD / ACCESS_EXTERNAL_SCHEMA` 无法解析。主流程已允许把两处常量引用替换为 JDK 21 `javap -constants javax.xml.XMLConstants` 核对的同值属性 URI；空值安全约束保持。基线与优化构建均使用这项修正，不把它记作 Bundle 加载收益。

| 用例 | 验收目标 | 基线预期 |
| --- | --- | --- |
| PreparedFilePreservesBytesAcrossReadBoundaries | 1 / 8191 / 8192 / 8193 / 2MiB / 20MiB 字节完整 | 通过 |
| PreparedFileAllocatesOnePayloadBuffer | warm 后 3 次读取 2MiB，ART 近似总分配 < 1.5 倍总载荷 | 失败；旧扩容及 toByteArray 产生额外数组 |
| PreparedFileRejectsEmptyAndOverLimit | 空与 20MiB+1 文件拒绝 | 通过 |
| PreparedFileRejectsChangedLengthSnapshot | stat 与实际长度不一致拒绝 | 失败；旧实现未复核长度 |
| PreparedFileCancellationIsCheckedBeforeRead | stat 后取消，读取报取消 | 通过 |
| PreparedBytesAreSameInstanceAndReleasedAfterConsumption | callback 原对象、消费后源字段空、第二次不能复用 | 失败；旧字段一直持有 |
| MismatchedUrlDoesNotConsumePreparedBytes | URL 不匹配不消费，随后匹配可消费并释放 | 失败；释放断言 |
| CloseReleasesUnconsumedPreparedBytes | close 释放尚未消费源 | 失败 |
| ConcurrentRequestsConsumePreparedBytesOnlyOnce | 两次并发只允许一次消费，源释放 | 失败；释放断言 |
| WarmLeaseReadsEachManifestOnlyOnce | 一次 lease 主 / Async Manifest 各只读一次 | 失败；旧实现主 3 / Async 2 次 |
| LeaseValidatesUnrequestedMainAndAsyncObjects | 非目标主 Bundle 或其他 owner 的 Async 损坏仍拒绝 Release | 通过 |
| OldLeaseKeepsAResourcesAfterBIsInstalled | 更新到 B 后旧 lease 固定 A 资源、新 lease 固定 B | 通过 |
| InvalidAsyncOwnerUrlAndAmbiguousShortNameAreRejected | owner、URL 校验和短名歧义边界保留 | 通过 |
| QueuedPreparedRequestClosePreventsFallbackAndCallbacks | 排队后close再放行，TLS连接/回调均0，源字段空 | 首个opt实测红：TLS1 / callback0 |
| PreparedFileClosedAfterClaimHasNoCallbackOrFallback | claim后读取边界close，TLS/回调均0 | 修后通过 |
| CloseBeforeRemoteCallRegistrationHasNoNetworkOrCallback | cache定位时close，Call登记窗口不漏网络 | 修后通过 |
| CloseAfterRemoteCallRegistrationCancelsBeforeConnect | 真实OkHttp拦截器确认Call已登记后close，连接/回调均0 | 修后通过 |

文件读取边界用现有 `loadFile` 反射调用；预备字节的释放用 `preparedBytes` 反射观察。测试不新增生产 hook。`File.length()` 的可控测试对象模拟 length snapshot 后缩短和增长，不依赖任意 sleep。

清单读次数测试先取得 warm lease，让 Android 纳秒文件身份 SHA 缓存命中，再以 `FileObserver` 观察两个 Manifest 目录的 OPEN 与 CLOSE_NOWRITE。每个目录都用独立 marker 的 CLOSE_NOWRITE 做事件 barrier；被测 lease 在 barrier 后才关闭，排除 `lease.close -> prune` 产生的读取。根据当前源码，每次 JSON 文件读取对应一次 parser 调用，此指标证明本地清单读取复用，网络计数不参与该断言。[FileObserver 官方文档](https://developer.android.com/reference/android/os/FileObserver)

分配用例使用公开 `Debug.getRuntimeStat("art.gc.bytes-allocated")`，先 warm 3 次，再测 3 次 2MiB 读取。不主动 GC、不 reset 全局计数；通过 instrumentation stream 记录近似分配和耗时。该统计为进程级近似值，不能等同于精确单线程复制计数或峰值 RSS，耗时仅作模拟器本次观测。[Debug 官方文档](https://developer.android.com/reference/android/os/Debug)

独立审查后补齐4个关闭竞态用例。ART允许反射替换现有private static final ioExecutor为GateExecutor，仅控制测试的task排队点并finally恢复；未增加prod seam、公共ABI或修改线程池。TLS计数器不提供证书，记录真实连接尝试，以marker socket握手作accept顺序barrier，任务完成后判断0，不靠任意sleep。Call登记前用ContextWrapper的filesDir定位边界关闭；登记后通过现有OkHttpClient applicationInterceptor反射，确认activeCalls=1才关闭，再验证取消与集合清理。

测试内 loopback ServerSocket 下载确定性字节，用于文件、校验与 A/B lease 回归，不能当作真实 Lynx 页面渲染验收。真实 Bundle 的 small/large/Async 同夹具基线与优化渲染对照由本轮自建 Rspeedy Fixture 另行执行并单列报告。

真实渲染入口为`BundleLoadingRealBundleTest#testRealFixtureSmallLargeAndAsyncRender`。主流程把最终`fixture-final-out/fixture-metadata.json`的`cases`与真实Android完整ReleaseManifest合并为描述，用`adb shell -T run-as ... tee`写到隔离App的`files/bundle-loading-fixture.json`；描述不带client token。通过`-e runLabel baseline|optimized`对同一夹具、同一harness分别执行。三个Bundle为BundleLoadSmall/BundleLoadLarge/BundleLoadAsync，每项必须同时收到真实SDK首屏、无fatal，并在真实LynxView找到`id=bundle-bench-ready`的SDK UI节点、精确accessibilityLabel和正布局尺寸，不能同时有错误节点；Async标签含执行后的10模块数量与checksum。Android4.1实测该text为FlattenUIText，没有对应native View，所以不从空contentDescription放行。Native handler另精确核对事件payload及source pageId/generation。READY后等待两次postOnAnimation帧再截图，避免SDK布局完成但compositor尚未显示的截图。测试走生产ContainerFactory/TemplateProvider/SidecarFetchers和页面lease，反射调用现有internal LynxShell.destroyView路径，不新增公共ABI。在App私有`files/bundle-loading-results/<runLabel>/`保存逐项JSON与PNG，不清App data；main-idle后的迟到计数只覆盖该观察窗口，不代表Activity全生命周期或无泄漏。

声明工具链：Gradle 8.11.1、Android Studio JBR 21。构建环境使用 `LYNX_OTA_DEVICE_E2E=1 LYNX_OTA_LOCAL_SERVER=1` 启用已存在的隔离宿主，清空 `LYNX_OTA_CLIENT_TOKEN`，不读取本机签名/client 配置。命令必须指定 `adb -s emulator-5554`；物理设备禁止操作。

基线 / 最终执行命令（需在主流程完成模拟器准备后执行）：

```bash
adb -s emulator-5554 shell am instrument -w \
  -e class com.example.lynxshell.sample.BundleLoadingOptimizationTest \
  com.hugboga.custom.otae2e.test/android.test.InstrumentationTestRunner
```

完整结果记录在 `/tmp/codex-bundle-loading-opt-20261009/implementation/results/android.md`，构建与设备证据独立列出。本说明中的“基线预期”是读源码制定的预期，执行前不视为实际结果。
