# Harmony 软件对齐

当前分支：`codex/harmony-native-parity`，基线`b5d649e`（原生PR20）。本轮地图延期，高级转场包含；仅源码实施与独立审查，不编译、不新单测、不运行既有测试或设备。后续Git交付按用户明确授权执行。

- [可读HTML实施与边界报告](implementation-report.html)
- [61项手工验收设计](acceptance-cases.md)

2026-10-05源码阶段完成：OTA/Shell/媒体、Cap Core与高级导航/转场已完成源码修正和有界独立复核。[审查范围与结论](source-review.md)。全部61项手工用例未执行；未编译、未运行、未测量性能。不能把“源码通过”当作Harmony运行验收；旧双端六项测试报告也不覆盖本轮Harmony。


## 本轮交付位置

- 原生：当前worktree的`codex/harmony-native-parity`，基线为`b5d649e`；本轮修改仅在Harmony源码及相关文档，Android/iOS源码未改。
- packages/模板：`LynxAppPackagesAndTemplates`的`codex/lynx-template-media-query`。本轮加入Harmony平台类型、Device未知虚拟状态、媒体Demo结果消费、媒体说明和独立changeset；其它既有dirty保留，未生成Bundle。
- 项目地图和两份已有Obsidian主题笔记已同步新的源码事实，历史运行证据仍保留原日期。
- 源码阶段未执行Git交付；后续commit/push/PR以托管平台记录为准，不作为运行验收证据。HTML浏览器效果验证未完成：浏览器工具安全策略禁止file协议，本轮没有绕过；本地报告文件已保存。
