# I1 — Discovery and RED tests

Objective: 盘点 iOS 真实调用链、旧路径、测试入口和用户脏改动；先写可观测失败测试。

Ownership: iOS 只读盘点、OtaIOSSDK tests、packet result。

Do: 路径隔离、十版本保留、candidate、delete、staging、capacity、commit fault、cold prune 测试。

Do not: 在 RED 之前改生产代码；不修改 Android/Harmony。

Verification: focused `swift test` 必须因缺失 Store v2 行为失败。
