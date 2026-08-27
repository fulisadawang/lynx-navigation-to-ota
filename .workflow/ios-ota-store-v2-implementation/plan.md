# iOS OTA Store v2 Implementation

## Goal

把 iOS OTA Runtime 对齐已完成的 Android Store v2：按 App ID 物理隔离、远程版本有界保留、
活体 UIViewController/Tab lease、冷启动 orphan/staging 清理，以及原生只读 OTA 磁盘浏览器。

## Success criteria

1. `10000009/V5` 与 `10000010/V5` 可同时安装、读取和删除，互不覆盖。
2. OTA 临时与发布路径为 `apps/<appId>/.staging/...` 和 `apps/<appId>/releases/...`。
3. 连续 V1...V10 后普通模式只保留 current/previous；candidate 模式最多额外保留 candidate。
4. 活体普通页面与 Native Tab 持有 Release lease；显式删除不会破坏仍在显示的页面。
5. 最后一个 lease 释放后回收目录；冷启动清理 Store v2 orphan/staging。
6. embedded baseline 继续直接读取 App Bundle，不复制 Bundle bytes 到私有 Store。
7. iOS Launcher 可进入原生只读 Inspector，展示真实路径、状态、角色、文件树和字节数。
8. Swift tests、静态检查、Xcode Debug 构建与模拟器运行态验收通过。

## Scope

- `ios/OtaIOSSDK` Store Core 与 tests。
- `ios/LynxShellKit` OTA runtime、UIViewController、Tab 承载和公开 Router 接缝。
- `ios/LynxShellSample` Launcher 与原生 Inspector。
- iOS 文档和测试报告。
- 不修改 Android/HarmonyOS 实现。

## Constraints

- Demo 通过删除模拟器 App/重装获得空沙盒；不实现旧 Store 迁移或 reset。
- 同一个安装包只绑定一个 env/hostApp/platform，不在 Store 路径中并存 TEST/PROD。
- App ID 继续遵循服务端 8 位数字契约。
- 必须保护当前工作树中既有 iOS 修改，特别是 project.pbxproj 与转场协调器。
- 不执行 Git commit/push/merge，除非用户另行要求。
- 服务端任意历史版本强制回滚字段不在当前契约中，本轮不自行发明。

## Work packets

- I1: 盘点 iOS 当前 Store/runtime/container/Launcher 与既有脏改动，固化 RED tests。
- I2: 实现 Store v2 路径、schema、retention、candidate、delete、cold prune。
- I3: 实现 Release lease，并接入普通 UIViewController 与 Native Tab 生命周期。
- I4: 实现 OtaStorageDiagnostics 与原生 Inspector/Launcher 入口。
- I5: Swift tests、静态检查、Xcode 构建、模拟器真实 OTA/Inspector/Tab 验收与 HTML 报告。

## Integration policy

- 测试先行，逐包 RED → GREEN。
- Core prune 与容器 lease 必须作为同一交付闭环。
- 既有 iOS 脏改动只做增量合并，不回滚、不大范围格式化。
- Android 是行为契约参考，不复制 Kotlin 实现细节。

## Verification

```text
swift test（OtaIOSSDK focused + full）
python3 scripts/static_check_android_ios.py
python3 scripts/static_check.py
xcodebuild Debug Simulator
simctl / 可用 XcodeBuildMCP 的 UI、截图、日志验收
git diff --check
HTML tidy
```

## Approval

用户已明确要求按 Android 做法完成 iOS。模拟器卸载/重装仅作用于 Demo，属于已授权验收步骤。

## Outcome

- I1–I5 全部完成，测试按 RED → GREEN 推进。
- iOS Store v2、容器 lease、只读 Inspector、文档与 HTML 报告已集成。
- 最终验证：47 Swift tests、111 Android/iOS 静态项、191 三端静态项、Xcode Debug build、
  真实 TEST OTA 与 Simulator UI 全部通过。
- 详细证据见 `results/verification.md`、`results/integration.md` 与 `final-report.md`。
