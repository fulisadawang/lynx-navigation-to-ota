# iOS Bundle 加载优化用例与基准计划

## 本轮顺序和范围

先提交可编译的测试与此验收合同，取得旧实现的行为 Red 后，再修改产品代码。第一阶段不修改 Podfile、Xcode 配置、产品接口或 Debug seam。SDK 测试已使用真实 `OtaSDK.prepareResources` 和磁盘对象，不以编译失败表示复现。

仅优化固定页面的 Async 清单读取/解码次数，以及 Native Tab 主包字节读取的线程归属。不得扩展到 GC、页面保留、校验缓存、下载并发池或其他协议。

## 已先写的 Core 用例

| 用例 | 基线预期 | 优化后预期 |
| --- | --- | --- |
| SDK prepare 后移除清单，再读取十个目标 | 十次 `missingLocalResource`，行为 Red | 十次读取成功，证明页面不再依赖该 JSON |
| SDK prepare 后损坏清单，再读取十个目标 | 十次 `missingLocalResource`，行为 Red | 十次读取成功 |
| 损坏后新开页 | 拒绝 | 仍拒绝，不能由全局缓存掩盖损坏 |
| 目标对象替换成同大小其他字节 | SHA 拒绝 | 仍拒绝 |
| 目标对象变短 | size 拒绝 | 仍拒绝 |
| 其他 owner 的独有请求 | 拒绝 | 仍拒绝 |
| 请求键、单前导斜杠、完整声明 URL | 返回同一真实字节 | 保持行为 |
| query、fragment、穿越、编码分隔符 | 拒绝 | 保持行为 |
| 同一 owner 多项别名指向同一完整 URL | 歧义请求拒绝 | 仍拒绝，索引不能覆盖掉冲突 |
| 页面关闭 | 新读取及媒体 URL 拒绝 | 保持行为 |
| close 时有读取在途、包含 cancellation | 完成/取消后才能 cleanup 和 drain | 保持顺序与一次性清理 |

## Tab / Page 模拟器回归

目标为独立 `com.codex.lynx.bundleloading` 的 E2EHost，iPhone 18 Pro Max / iOS 27 模拟器 `2E98C9AA-9D32-4EEC-9A2E-E83BD90EDD6C`。不启动 VPhone、真机或清除用户数据。

真实模板产物由主 Agent 提供，App ID `10030071`，主包小/大和 Async 脚本。宿主选择真实 Store 安装的固定 Release；如使用测试 DI，其返回值必须指向真实模板文件和真实已验证资源快照，不能用空数据或假成功绕过 Runtime。

| 宿主用例 | 验收 |
| --- | --- |
| Tab 首次加载小/大主包 | 显示模板首屏；实际 `Data(contentsOf:)` 线程为非主线程 |
| Page 同一主包加载 | 保持现有 detached IO 与正常首屏，作为路径控制组 |
| Tab 读取过程中 refresh generation | 旧字节完成后不 render，新 generation 单独 render；旧 lease/resources 清理 |
| Tab 读取过程中取消/离开 | 不向已失效 View 投递，错误和取消不被当作成功 |
| 缺失/损坏主包 | 真错误；没有首屏/假成功；不吞异常 |
| 普通 Tab 切换 | 实例和 generation 复用，不额外网络请求或主包重读 |
| Async 多目标和关闭过程中请求 | 全部字节真实；关闭/在途 drain 与 Core 行为一致 |

Core Red 不能替代 Tab UIKit 回归，MainActor 心跳指标也不能单独证明磁盘读取线程。

## 分段 Benchmark 合同

基线与优化使用同一模板 SHA、同一模拟器、同一宿主代码和测量入口。先完成公共测试 harness 的 baseline 测量，再修改优化实现并测量；不要用已优化构建倒推基线。使用独立沙盒，不清其他 App 数据。每组 3 次预热、至少 10 次可比较样本，分别记录小/大主包、Page/Tab，输出原始数据与 median/p95，不只给平均值。

记录边界：

1. `resolve_started → resolve_completed`：本地 fixed Release/lease 获取。
2. `resources_started → resources_completed`：清单本地读取、校验、解码、owner 索引和路径准备。
3. `source_read_started → source_read_completed`：实际主包字节读取；记录 bytes、readStartedOnMainThread、持续时间。
4. `view_create_started → load_submitted`：主线程 LynxView 创建及输入提交。
5. `load_submitted → first_screen`：真实 Lynx 首屏回调；失败样本标失败，不能丢弃。
6. `open_started → first_screen`：端到端耗时，同时报告 Async 目标数、目标字节校验数量和错误。

UIKit 全过程保留 16 ms 主线程心跳/最大 gap 作为辅助指标；模拟器不宣称手机 FPS 或真实设备性能。文件 `.mappedIfSafe` 读 span 是取得 Data 的时段，内存映射后的分页成本可能落在随后 Lynx 解码；必须保留首屏段，不能用更短 source span 直接宣称总体性能改善。

当前没有 `Data(contentsOf:)` 的线程计数 seam。第二阶段需先添加最小 **DEBUG、内部、测试限定** 观察点，确保 baseline/optimized 使用同一 harness：读取开始/结束只记录 generation、bytes、线程和单调时钟，不记录 token、请求头、私有 URL 或绝对用户路径；Release 不增加行为、协议和公开 API。首屏继续使用既有 Observer/Monitor，不返回假首屏。清单复用由 Core 删除/损坏文件测试提供独立证明；若增加 decode 计数必须作用在实际 JSONDecoder 调用点，不能从 resolver 次数推算。

## 环境边界

第一阶段只探查 CocoaPods；新工作树没有 Pods，存在已有本机缓存。后续正常 `pod install --no-repo-update`，锁定既有版本；不手改 Pods，不升级依赖。构建 App ID 只用 target-specific 设置，避免全局 `PRODUCT_BUNDLE_IDENTIFIER` 污染 `org.cocoapods.LynxResources`。必要的 Xcode 27.1 `IPHONEOS_DEPLOYMENT_TARGET=15.0` 仅单次构建覆盖，不修改项目兼容策略。

完整报告区分 Core、宿主/模拟器首屏、性能样本与未验证的设备范围。零失败回归和足够样本完成后才给优化结论。
