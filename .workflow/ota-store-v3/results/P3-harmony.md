# P3 Result — HarmonyOS Store v3

## 结论

HarmonyOS Store v3 已在 DevEco 模拟器上完成当前代码的构建、真实本地 HTTP OTA、ArkUI Tabs、磁盘 Inspector、故障注入和 HDC force-stop 恢复验收。Runtime 使用 `ContentAddressedOtaStore`，不实现 candidate/trial；Store 使用完整 Manifest、App ID 作用域 CAS、原子 State、Page/Tab lease、NavigationSnapshot 和 Mark-and-Sweep prune。

## 构建与静态证据

- `assembleHar --mode module -p module=lynx_shell_kit@default --no-daemon`：exit 0，`BUILD SUCCESSFUL`。
- `assembleApp --no-daemon`：exit 0，`BUILD SUCCESSFUL`。
- `python3 harmony/scripts/check_harmony_shell.py --quiet`：`89 PASS / 0 WARN / 0 FAIL`。
- `python3 scripts/static_check_android_ios.py --quiet`：`111 PASS / 0 WARN / 0 FAIL`；跨端静态门禁合计 `200 PASS / 0 WARN / 0 FAIL`。
- `node scripts/verify-ota-store-v3-fixture.mjs`：exit 0；100 个 Bundle，只有 index 050 变化。
- `scripts/ota-store-v3/run-harmony-fault-tests.sh`：10 个 TEST-only 事务/ENOSPC 故障点、capacity=0 和 server disconnect 均执行，并由 `assert-harmony-results.mjs fault` 自动断言通过。
- `scripts/ota-store-v3/run-harmony-process-crash-tests.sh`：5 个提交边界 HDC force-stop 均执行，并由 `assert-harmony-results.mjs process-crash` 自动断言通过；保护启动和正常恢复均为 Bundle=0。
- 删除验收：活体 lease 存在时先保护远程对象；force-stop 后新进程启动恢复并 prune orphan，Inspector 显示 files=0、CAS=0、Manifest=0；直接打开 rawfile baseline 的 OTA 请求为 0。
- NavigationSnapshot：Demo 同 session 连续打开两个 OTA Page，HDC 日志显示两次使用同一个 Snapshot ID；返回宿主页后再打开内置基线创建新的 Snapshot。
- Hvigor 仍输出 Lynx/ArkTS 依赖既有 warning，并提示未配置 `signingConfig`；本轮没有伪造签名发布包。

## 运行态证据

设备：DevEco 模拟器 `emulator`，HarmonyOS `6.1.0.126(SP1DEVC00E120R4P11)`，HDC `127.0.0.1:5557`。本地 Server 监听 `0.0.0.0:18766`，模拟器通过 `10.0.2.2:18766` 访问；Server 返回的请求平台按当前 Demo 兼容约定为 `android`，宿主身份仍为 HarmonyOS。

| 场景 | Server / 页面结果 |
|---|---|
| 干净安装 V1 | latest=1，Bundle=100，8,775,400 bytes；页面显示 V1-050 |
| V1 → V2 | latest=1，Bundle=1，87,754 bytes；唯一请求 `pages/10000001/bundle-050.lynx.bundle` |
| V2 下一次冷启动 | 页面显示 V2-050；没有再次下载其余 99 个 Bundle |
| ArkUI Tabs 切换 | latest=0、Bundle=0；Home/Settings 不触发 OTA |
| Tab 主动刷新 | latest=1，Bundle=1，87,754 bytes；两个 Tab 重建并显示 V2-050 |
| ETag | 重复刷新返回 304；Bundle=0、bytes=0 |
| 坏 SHA | 同步失败，current 保留旧版本；没有提交坏 Manifest/State |
| Inspector | `/data/storage/el2/base/haps/lynx_shell/files/lynx-ota-store`；current=V2、previous=V1、CAS=101、Manifest=2、files=104 |

截图报告：`docs/harmony-ota-store-v3-test-report.html`。

## 已修复的实现问题

1. 首轮 Harmony 下载发现二进制临时文件被错误拼接为 `.part.part`，修正为直接写入事务 `.part` 后再原子移动到 CAS Object；修复后 V1/V2 真实请求和磁盘计数均通过。
2. ArkTS 不接受 Map 的内联对象类型，补充显式 `OtaHttpCacheEntry`，ETag 编译和运行态 304 均通过。
3. 静态脚本原先检查旧 v2 `ReleaseTransaction`，改为检查实际 v3 CAS/Manifest/State 主链，避免旧文件存在时产生虚假的门禁通过。
4. 新进程初始化增加 transactions recovery 和 roots prune，确保 delete 后无 State/lease 的 orphan 不会永久残留。
5. CAS Object 发布和原子文本写入补充文件及父目录 `fsync`；有效 `transaction.json` 在失败进程恢复前保留，`.part`/临时文件清理，已发布对象在下一次安装前仍作为 root 参与 prune。

## 未覆盖

- HarmonyOS 物理真机、签名发布包和生产外部 Server/CDN/TLS。
- 真实断电/系统级异常终止（HDC force-stop 已覆盖进程终止，但不等同断电）。
- 真实 OS ENOSPC、不同目标 SDK 的 `fsync`/`rename` 兼容性。
- 本轮未在设备上同时安装两个不同业务 App；App ID 隔离由源码门禁和路径实现证明。
