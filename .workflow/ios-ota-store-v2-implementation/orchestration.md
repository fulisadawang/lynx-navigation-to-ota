# Orchestration

1. I1 只读盘点并记录基线；确认既有 iOS 脏改动边界。
2. I1 写 Store v2/retention/lease/diagnostics 失败测试并观察 RED。
3. I2 完成 Store Core GREEN，先跑 focused 再跑 full Swift tests。
4. I3 在 Core GREEN 后接入 VC/Tab lease；所有放弃的 prepare 结果必须 close。
5. I4 基于只读 snapshot API 完成 Inspector，不允许 UI 自行扫描任意路径。
6. I5 从最终源码重新执行全部验证；失败回到所属 packet，不绕过。
7. 集成报告区分：已通过、历史证据、模拟器证据、真实 OTA、未覆盖边界。

分支规则：

- 服务端不可用：使用既有 mock/fault fixtures 验证 Core，但模拟器真实 OTA 标为未通过。
- XcodeBuildMCP 不可用：使用 xcodebuild/simctl，并明确工具边界。
- project.pbxproj 与既有修改冲突：优先复用已编译文件或精确追加，不覆盖原 diff。
