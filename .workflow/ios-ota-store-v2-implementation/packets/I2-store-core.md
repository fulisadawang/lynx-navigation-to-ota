# I2 — Store Core

Objective: 实现 iOS Store v2、schema 2、app-scoped staging/releases、prune/delete/cold maintenance。

Ownership: `ios/OtaIOSSDK/Sources/OtaIOSSDK`。

Do not: 迁移旧 Store；不引入 TEST/PROD 双层路径；不发明 server rollback 字段。

Verification: I1 focused + full Swift tests。
