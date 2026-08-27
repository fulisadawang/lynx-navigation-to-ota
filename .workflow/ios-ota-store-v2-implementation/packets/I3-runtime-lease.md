# I3 — Runtime and lease

Objective: 把 Release lease 接入普通 VC 与 Native Tab，保证删除/prune 不破坏活体页面。

Ownership: iOS runtime/container/tab 相关 Swift 文件。

Do: stale prepare、失败、replace、pop、deinit、Tab reload 均释放 lease；先销毁内容再 close。

Do not: 修改转场语义；不覆盖现有 `ShellTransitionCoordinator.swift` 用户改动。

Verification: lease Core tests、Swift parse/Xcode compile、模拟器 Activity/Tab smoke。
