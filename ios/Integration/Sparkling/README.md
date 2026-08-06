# iOS Sparkling 可选适配

默认 target 不包含本目录的 `.sample`。当前 Sparkling Playground main 的 Podfile 仍锁定 Lynx 3.9.0，因此必须先完成 Sparkling ↔ Lynx 4.0 对齐，再启用。

建议保持 `LynxPageRequest`、`ShellNavigator` 和 Bridge 契约不变，只替换容器创建层：

- 启动：`SPKServiceRegister.registerAll()`、`SPKExecuteAllPrepareBootTask()`。
- 页面：`SPKContext` + `SPKContainerView.load(withURL:context:)`。
- 路由：`SPKRouter.create(withURL:context:frame:)`。
- Release 与 Debug Tool 分 target / 编译条件隔离。
