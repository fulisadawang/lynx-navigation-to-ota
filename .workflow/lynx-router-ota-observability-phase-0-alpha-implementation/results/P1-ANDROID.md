# P1-ANDROID 结果

## 已完成

- 新增 `android/lynx-shell/src/main/kotlin/com/example/lynxshell/telemetry/`：
  `TelemetryModels`、`TelemetryCoordinator`、`ExposureSessionTracker`、`TelemetrySink`、
  `LynxTelemetryRuntimeAdapter`。
- 新增 `android/lynx-shell/src/test/kotlin/com/example/lynxshell/telemetry/TelemetryCoordinatorTest.kt`。
- Coordinator 保持 Activity-first 路由和 OTA 主链不变；accepted 与 transition terminal 分开，页面/App 状态正交，旧 generation 丢弃，snapshot 在 prepare 前/成功后冻结，page_open 按 attempt 幂等。
- `toWireMap()` 输出 shared canonical snapshot/lifecycle/privacy 字段，省略顶层 null 可选对象，不输出本机绝对路径。

## 验证

```text
git diff --check -> PASS
python3 scripts/static_check.py -> Android/iOS 110 PASS, Harmony 62 PASS
```

`[待确认]` Android Gradle 单测未能运行：仓库没有 Gradle wrapper；使用本机 Gradle 8.9 时当前 JDK 为 25.0.2，构建在配置阶段因 `25.0.2` 失败；本机另有 JDK 11，但 AGP 要求 Java 17，仍不能完成编译。
