# HarmonyOS 壳安全边界

## 远程 Bundle

- 默认只允许 HTTPS；
- 不限制远程 Host；
- URL Path 必须以 `.lynx.bundle` 结尾；
- 响应必须是 2xx；
- 内容不能为空；
- 单文件最大 20 MB；
- 连接超时 15 秒，读取超时 30 秒。

## HTTP 调试

只有同时满足以下两项才允许 HTTP：

1. `ShellSecurityPolicy.ALLOW_DEBUG_HTTP = true`；
2. 页面路由 `allowHttpInDebug=true`。

交付默认第一项为 `false`。

## 本地路径

只允许 rawfile 相对路径；拒绝 `/` 开头、`..`、反斜杠和空字符。

## Redirect

HarmonyOS HTTP API 的最终跳转 URL 暴露能力需要在真实 SDK 中进一步验证。当前不限制入口或跳转目标 Host；如业务需要限制重定向，应在网络层接管并逐跳校验。

## Native Module

- Storage Key 非空且最长 128；
- 存储使用独立 Preferences Name；
- 页面 URL 仍经过同一 `LynxRouteParser`；
- Bridge 只暴露固定方法，不接受可执行代码或原生类名。
