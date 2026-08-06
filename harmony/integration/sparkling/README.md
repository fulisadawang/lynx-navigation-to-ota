# Sparkling 与 HarmonyOS 的接入边界

本目录**不伪造 Sparkling Harmony Runtime 适配层**。当前参考的 Sparkling `main/packages/playground` 只有 Android、iOS 与前端 Playground，没有可直接作为事实源的 HarmonyOS 原生 Playground。

Harmony 壳只复用了 Sparkling Playground 中与平台无关的宿主设计思想：

- Bootstrap / Runtime 初始化集中化；
- Router、Provider、Context、Native Method 分层；
- `hybrid://lynxview_page?bundle=...` 路由参数兼容；
- Bridge 方法名稳定，不把 ArkUI Page 或 Ability 类型泄漏给 Lynx 页面。

正式主链路仍直接使用 Lynx `release/4.0` 的 HarmonyOS OHPM 包。以后 Sparkling 官方提供 HarmonyOS Playground 或完成可验证的 Lynx 4.0 Harmony 适配后，再在这里增加独立 Adapter，并保持它不影响默认壳工程。
