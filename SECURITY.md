# 三端安全边界

Lynx 页面能够调用宿主 Native Module，因此 **Bundle 地址就是代码信任边界**。默认策略是：本地可信、远程受控、HTTP 关闭、错误不伪装成功。

## 远程 Bundle

三端共同约束：

- 默认只允许 HTTPS；
- 当前壳不限制远程 Host；业务接入仍应通过签名、摘要、版本、灰度和来源策略控制代码信任边界；
- 模板路径必须以 `.lynx.bundle` 结尾；
- 响应必须为 2xx 且内容非空；
- 单文件最大 20 MB；
- 页面退出或重试时取消旧请求。

### Android

Manifest/Network Security 层关闭明文网络；Provider 不配置远程 Host 白名单。

### iOS

Release `Info.plist` 禁止任意 ATS 加载；入口 URL 和最终重定向协议重新校验，不配置远程 Host 白名单。

### HarmonyOS

`ShellSecurityPolicy.ets` 不限制远程 Host，仍强制 HTTPS、`.lynx.bundle` 后缀、响应码和体积上限。当前 Harmony HTTP API 的最终跳转 URL 暴露能力仍需在目标 SDK 里做编译/真机验证；生产 CDN 应关闭跨域重定向，或由业务网络层接管并逐跳校验。

## HTTP 调试

HTTP 必须同时满足：

1. 宿主 Debug 开关显式开启；
2. 页面路由携带 `allowHttpInDebug=true`。

交付默认关闭。生产包不应通过页面参数单独打开 HTTP。

## 本地路径

Provider 拒绝空路径、绝对路径、`..`、反斜杠和空字符，只允许 App 自身资源相对路径。

## 深链输入

`lynxshell://`、`lynx://` 和 `hybrid://` 可能由外部 App 触发。业务接入仍应：

1. 不使用深链 `initData` 直接决定登录、支付、账户或权限状态；
2. 对页面 ID、登录态和业务来源建立白名单；
3. 对远程 Bundle 增加签名、摘要、版本、灰度、回滚和缓存校验；
4. 按页面来源限制高权限 Native Module。

## Native Module

当前模块只提供 Router、Storage 和 AppInfo。敏感数据不要放入普通 Storage；支付、相机、定位等必须使用独立模块、权限校验和用户确认。
