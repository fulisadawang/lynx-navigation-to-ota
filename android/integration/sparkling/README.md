# Android Sparkling 可选适配

本目录不进入默认 `app` SourceSet。`.sample` 文件展示如何把当前直连 Lynx 容器替换为 Sparkling HybridKit，同时复用业务 `LynxPageRequest` 与 Router。

启用前：

1. 先把 Sparkling Android 依赖与 Lynx 4.0 对齐。
2. 把 `.sample` 改为 `.kt` 并放入实际业务模块。
3. 注册业务自己的 Network、Permission、ThreadPool、Router、Media Depend。
4. 不要同时让 Sparkling 与 App 各自重复初始化不同版本的 LynxEnv。
