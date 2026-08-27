# I4 — Native Inspector

Objective: iOS Launcher 增加只读 OTA 磁盘浏览器。

Ownership: diagnostics model/API、Launcher/Inspector UI、必要的精确项目引用。

Do: 展示 root、App ID、state、candidate、roles、files、bytes、staging；后台扫描、可刷新、可返回。

Do not: 网络请求、删除/修改文件、接受任意外部扫描路径。

Verification: snapshot tests、Xcode build、模拟器 UI/返回/刷新。
