# P4 Result — 最终跨端审计

## 已通过

- Golden Fixture：100 个 Bundle，V1/V2 只有 050 改变，验证脚本 exit 0。
- iOS 静态门禁：111 PASS / 0 WARN / 0 FAIL；Swift 单测 54/54；XCUITest 默认回归 7 passed、0 failed、3 skipped，本地真实 OTA smoke 1 passed、0 failed、0 skipped。
- Android 静态门禁：已包含在跨端 `111 PASS / 0 WARN / 0 FAIL`；Store v3 JVM 47/47，0 failed、0 skipped；Debug APK 构建成功。
- Harmony 静态门禁：89 PASS / 0 WARN / 0 FAIL。
- 三端汇总静态门禁：200 PASS / 0 WARN / 0 FAIL。
- 三端均完成本地 Golden Fixture V1 全量 100 个 Bundle → V2 只请求并写入 050 的 1 个变化对象；完整 Manifest 仍为 100 条，未变化 Bundle 复制数为 0。
- iOS、Android、HarmonyOS 均验证 Native Tab 普通切换零 OTA 请求、主动刷新重建内容、冷启动读取已提交版本和 ETag 304。
- Harmony TEST-only 故障矩阵：10 个事务/ENOSPC 故障点 + capacity=0 + disconnect，均有 JSONL 结果和自动断言。
- Harmony HDC force-stop 矩阵：5 个 Object/Objects/Manifest/State 暂停边界，保护启动和正常恢复通过；恢复阶段 Bundle=0、CAS=101。
- Harmony 删除/回收/内置基线：delete → force-stop → 空 latest 启动后 files=0、CAS=0、Manifest=0；rawfile 直读没有 OTA 请求。
- Harmony NavigationSnapshot：同 session 双 Page 复用同一个 Snapshot ID，退出后新 session 建立新 Snapshot。
- 三份独立 HTML 报告、截图和本地 JSONL/文本证据均存在；报告中的相对图片/实现/结果链接通过引用校验。
- `git diff --check`、JavaScript 脚本语法检查和 workflow artifact 校验通过。

## 运行态边界

- iOS：iPhone 16 Pro / iOS 18.1 Simulator；本地 URL 仅由测试 harness 注入。
- Android：`emulator-5554` / Android API 35 arm64 模拟器；使用独立 ADB 端口避免 AndroMeld ADB 服务互相抢占。
- HarmonyOS：DevEco 模拟器 `emulator` / HarmonyOS 6.1.0.126；HDC `127.0.0.1:5557`；最终产物为 unsigned `.app`。
- 本地 Fixture Server 只替代外网 OTA 服务，不替代真实生产 CDN/TLS；Harmony Demo 为复用当前 Fixture，向 Server 请求 `platform=android`，宿主页面身份仍是 HarmonyOS。

## 仍然明确标记为 BLOCKED

- HarmonyOS 物理真机和三端签名发布包。
- 真实断电/系统级异常终止；HDC force-stop 只能覆盖进程终止路径。
- 真正的 OS ENOSPC 中途写入，以及不同目标 SDK 的 `fsync`/`rename` 兼容性。
- 本轮没有在设备上同时安装两个业务 App 做双实例物理隔离；App ID 作用域由源码门禁和路径实现覆盖。
- 生产外部 OTA Server/CDN/TLS 的真实环境验收。

这些边界已写入三端报告，不把静态、JVM、模拟器、受控容量或本地 Server 证据升级成物理真机、真实断电、真实 ENOSPC 或生产环境通过。
