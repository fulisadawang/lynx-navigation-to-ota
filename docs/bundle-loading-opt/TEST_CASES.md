# Bundle 加载优化：测试先行用例

基线：远程 `main@b3837d491069dd5409d78dad75276201c54edaa3`；实施分支 `codex/bundle-loading-opt`。

用户要求：先写测试用例和可执行测试，再开发，最后执行同一套用例并交付报告。本文件在产品实现修改前创建；实际结果填写到测试报告，不将下列期望写成已通过。

## 范围与数据

- Android：主 Bundle 文件读取缓冲、预置字节一次消费、一次 lease 获取的清单复用。
- iOS：固定 PreparedResources 索引及 URL／owner 语义、Native Tab 文件 I/O。
- HarmonyOS：用户明确暂缓，本次不改实现、不执行该端测试。
- 不改变完整性、Release／owner、epoch、lease／drain、页面保留、线程池或 GC 策略。
- 自建真实 ReactLynx 夹具，复用现有模板已安装版本：ReactLynx 0.123.3、Rspeedy 0.16.3。夹具源码与产物分离；生成文件不提交。
- 三种运行输入：小主包、由确定性高熵数据实际参与计算的大主包、多个实际调用的 Async 脚本；按构建后的真实 size／SHA 归档。另有 owner／歧义／损坏／取消专用 Core 夹具，它们不冒充可渲染 Bundle。
- 原始基线与优化版使用相同 Bundle、测试宿主和数据，独立沙盒／App ID；模拟器数字不换算为生产真机评分。

## 冻结用例

| ID | 级别／平台 | 操作与输入 | 必须满足的断言 |
| --- | --- | --- | --- |
| BL-A01 | Android Provider | 读取小包、大包、二进制字节、短读 | 回调字节与文件完全一致；不截断、不返回默认空值；最终大小正确 |
| BL-A02 | Android Provider | 空文件、20 MiB 上限、上限＋1、读取期间取消／长度变化 | 非法输入明确失败；取消后不更新失效消费者；新读取方式保留原边界 |
| BL-A03 | Android Provider | preparedBytes 成功消费、关闭、并发请求 | 仅一次消费；消费／关闭后 Provider 不再持有无用源引用；交付字节正确；fallback 契约不改 |
| BL-A03-C | Android Provider | 排队后关闭、claim后关闭、Call登记前／后关闭 | 网络与缓存fallback不在关闭后启动；零失效callback；源与Call集合释放，gate控制顺序 |
| BL-A04 | Android Store／模拟器 | 已暖校验缓存后取得一个 downloaded lease；监视主／Async JSON OPEN，保持 lease 到观察结束 | 单次取包主清单和 Async 清单均复用解析结果；可靠事件 marker 收口；统计排除安装、SHA 冷读及 close GC |
| BL-A05 | Android Store | 原有跨 App、owner、同长度／mtime 篡改、固定旧页 lease 回归 | 隔离、SHA 检查、旧页版本绑定与回收语义保留 |
| BL-I01 | iOS Core | 真实 prepareResources 后移除／损坏已验证 Async JSON，再 resolve 10 个目标 | 已准备页使用固定索引继续读取正确对象；新 prepare 必须拒绝缺失／损坏 JSON；旧实现预计出现行为 Red |
| BL-I02 | iOS Core | 准备后损坏目标对象：同长度不同内容／长度变化 | 每次对象读取仍核对 size／SHA，旧索引不掩盖坏文件 |
| BL-I03 | iOS Core | 不同 owner 同键、同 owner 重复 URL、直接 URL 与 path 同时命中不同条目、非法 query／fragment | 字节与准备路径均使用 requestKey 与 URL 的 union唯一匹配；零／多匹配拒绝；路径仍仅在prepare期内容校验，字节resolve逐对象校验 |
| BL-I04 | iOS Core | A 页准备后切换 B、关后读取、在途读取时 close | 固定 Release；关后拒新读；在途 resolve 排空前保留必要 lease；不改变取消／drain 语义 |
| BL-I05 | iOS 模拟器／Tab | 加载大主包、取消后重载、迟到加载结果 | 文件读取离开 UI actor；generation／epoch／取消检查仍生效；只显示当前有效结果 |
| BL-H01（暂缓） | Harmony host 逻辑 | 同一 preparePage 的实际 readAsyncManifest 计数 | 校验与索引构造共用一次已验证解析；owner、URL和完整性检查保留；明确仅 host 逻辑证据 |
| BL-H02（暂缓） | Harmony host 逻辑 | preparedBytes 消费／取消、重复请求 | 交付内容不变；只消费一次；Provider 不继续持有无用源引用；generation／fallback 保留 |
| BL-R01 | Android／iOS 模拟器 | 安装独立测试宿主，打开真实小主包 | Lynx 实际首屏可见；页面显示确定性标记／数据计算结果，不以 root.render 调用当成功 |
| BL-R02 | Android／iOS 模拟器 | 打开真实大主包 | 实际大文件 size／SHA 已验证；首屏与必要脚本输出正确；记录 SDK准备、字节交付、首屏时间及输入缓冲证据 |
| BL-R03 | Android／iOS 模拟器 | 触发全部真实 Async 脚本／必要 lazy 组件 | 实际产物被请求／读取并执行；输出校验正确；固定快照；有错误时明确失败 |
| BL-R04 | Android／iOS 模拟器 | 重开／返回／同版本再次加载 | 同一组资源输出一致；普通原生路由行为不改；源输入引用按契约释放；无迟到结果污染 |
| BL-P01 | 对照／两模拟器 | 原始基线与优化版运行同一产物集与相同轮次 | 报告结构计数／源字节保留／分配模型与阶段时延；真实 OS 分配峰值没有证据就填未测，不以数组长度冒充分配下降 |

## 测试实现与判定规则

1. 产品源码修改前先落地 Android／iOS 回归测试；文档用例与可执行文件逐项关联。Harmony 按用户最新要求暂缓。
2. 能运行的基线先运行。初始行为失败作为 Red；缺诊断接缝明确记未覆盖，不能把编译错误当作已复现性能问题。
3. 计数／竞态用事件 barrier／gate，不用任意 sleep 证明顺序。原始字节引用与完整读取缓冲分别观察。
4. 没有可靠 decode 计数时，BL-I01 只证明准备后不重读 JSON，不宣称精确解析次数。对象 SHA 仍必须覆盖。
5. 源引用释放只证明宿主不保留无用输入，不代表 Lynx 模板／JS 内存释放或零拷贝。
6. 模拟器分别指定 Android `emulator-5554` 和 iOS `2E98C9AA-9D32-4EEC-9A2E-E83BD90EDD6C`；不操作已连接的 Android 真机或 VPhone，不清用户数据。
7. 性能记录与引用诊断分开；基线／优化数据集固定，不修改断言或阈值来迁就结果。
8. 最终每个 ID 填 PASS／FAIL／未执行、命令／日志／截图／产物身份和剩余边界。全部必需 Android／iOS运行用例通过后交付；Harmony不声称设备通过。
