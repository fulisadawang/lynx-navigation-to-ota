# Harmony 本轮源码审查结论

日期：2026-10-05。分支：`codex/harmony-native-parity`。基线：`b5d649eb989875c9ff7d1ce345e212042fcc9d88`。实际 Lynx HAR 4.1.0，Harmony 最低 API 13、目标 SDK 6.1.1/API 24。

## 结论与证据层级

Cap Core 独立审查与同实例 `lynx-ui-auditor` 的最终源码复核通过本轮有界功能审查；当前范围内没有剩余已确认的阻断问题。审查重新读取了 tracked 改动和新增文件，前置方案意见没有直接作为最终通过依据。

这是源码、官方 API 和真实调用链的结论。**未运行 parser、typecheck、Lint、既有测试、HAR/App 编译、设备操作或性能采集；61 项手工验收全部未执行。** 不把旧 iOS/Android 或旧 Harmony 构建、设备报告作为这批新源码的运行证明。

## 覆盖与已关闭的问题

| 范围 | 本轮最终源码复核内容 |
| --- | --- |
| Runtime / Host / Owner | SDK 薄 facade 与旧 Shell 共用 exact LynxContext Runtime；真实 Ability/UIContext/Window；前台 getter；销毁墓碑、一次回执和迟到任务拒绝。 |
| IO / Filesystem / HTTP / Transfer | 2 个执行槽和 16 个等待槽；bulk/编码使用 TaskPool；真实 native finally 后释放槽；CACHE/UTF8 默认、标准 URI、成功字段和原始字节预算。 |
| SQLite / Preferences | 实际连接生命周期、SQL 别名与绑定、分句、结果形状、BLOB、changes/lastId、readonly；真实事务/rollback 后关闭并解锁；Preferences 已开始提交完成 flush，Bridge 取消仍独立处理。 |
| 平台工具与媒体 | Audio 和窗口多 owner 隔离；真实权限、联系人、日历、定位、附件分享与生物认证；系统选择/拍摄、私有可写 saveUri、授权后实际 copy/fsync、原生 Image/Swiper/Video 与旧 Shell 同后端。 |
| OTA | 默认关闭候选模式；PENDING/TRIAL 与 SDK 首屏、业务 healthy 双信号；候选坏包稳定回退、旧 TRIAL 启动恢复、失败来源退休、隐藏 Page/Tab 恢复；末端 epoch/decision/精确 Manifest 与 lease；流式接收预算和原子 State/GC 根。 |
| Navigation / Shared / OpenContainer | 真实 Navigation/NavPathStack 与 interactive proxy；push 前 source 快照、目标真实首屏/selector/ready；Native onTransitionEnd 才提交或取消；每事务独立 Canvas、资源预算与迟到快照回收；live fallback 保留真实原因。 |
| 公共导航参数 | Shared 新旧声明、样式、Open 参数、routeType/options/config、透明承载、正反时长、secondary 联动、maintainState；Sheet/preset/hero 实际 consumer；命令 animated、去重和 result；同栈顶 no-op 与 reLaunch 真实 clear 后新会话。 |
| Prepared Route / 导航与 OTA 耦合 | 真实 Provider 字节与异步 SHA；4 条/32 MiB/30 秒、一次 token；warm 不改变 State、不 TRIAL、不创建正式 Snapshot；claim 重核身份和精确版本后建立正式 lease；失效缓存走正常 Provider，取消/来源/I/O 错误保留。 |
| Root 最后增量 | UI 命令 busy 1006 优先、真实前台来源 1002；不按 epoch 阻止活体旧页面退出；非 UI ready/read/message 不套 busy；SDK pop/popTo/closeAll 可选 options；Window edge 基线保持、实际 top 策略恢复。 |

## 需随交付保留的边界

- Shared 快照矩形洞目前用承载层常量背景，无法精确恢复元素背后的父渐变或图片底纹。它是具体的视觉表达差异，不按硬件豁免，也不宣称全场景像素一致。
- Harmony API 13 没有 `KeyboardAvoidMode.NONE`，`keyboardBehavior: nothing/none` 明确拒绝；API 14 及以上可使用。不是成功后静默换成 OFFSET。
- CameraPicker 系统录像不能关闭音轨，公共媒体参数显式 `includeMicrophone=false` 返回 UNSUPPORTED。设备缺摄像头、传感器或认证凭据另按真实可用性处理。
- NativeTab 在现有 iOS/Android 中仅为宿主锚点，不是 Lynx Page 结果 receiver；本轮没有新增 Tab 结果栈。Tab 业务仍可使用已有 session/message 机制。
- 原生 preset 曲线、几何和系统材质有平台差别；Hero 为透明全屏，由 Lynx 业务控制其内部动画，原生不重复裁剪。最终视觉与交互时序尚待运行验证。
- 64 MiB 快照与 32 MiB 预热是源码资产预算，不是整个 App 实测峰值；没有 FPS、长稳或零泄漏结论。ResultSet 的 UI 侧有界读取、短同步原子 rename、cached metadata/legacy 完整 buffer 路径仍需实际 trace。
- Push 厂商、后台 JS runner、SQLCipher 等在现有双端同样未配置；本轮保持真实 Provider 边界，没有初始化新的商业 SDK。地图按用户决定延期。
- Filesystem 省略 directory 已按共同契约改为 CACHE；旧 Harmony DATA 相对文件不会自动迁移，已有业务应显式指定 DATA。

## 入口

- [HTML 实施报告](implementation-report.html)
- [61 项手工验收设计](acceptance-cases.md)
- [公共导航契约](../../NAVIGATION_README.md)
- [转场契约](../../TRANSITIONS_README.md)

本报告记录源码收口阶段的结论；后续用户授权的 commit、push 和 PR 不代表新增运行验收。packages/模板独立交付，未生成新 Bundle。
