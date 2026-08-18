# OTA 服务端接入契约（API v1）

本文给服务端、CI/CD 和客户端开发者使用。字段和路径以当前三端 Router/OTA 客户端以及
`LynxOtaServer` 的实际实现为准，不把 Admin API 当成移动端 API。

## 1. 端到端职责

```text
CI/CD
  ├─ 生成 *.lynx.bundle
  ├─ 上传 OSS/CDN
  ├─ 计算 SHA-256 和字节大小
  └─ 创建并发布 ACTIVE Release 元数据
          │
          ▼
移动端 Router/OTA SDK
  ├─ 启动/回前台：读取全量 latest-bundle-list
  ├─ 页面打开：读取当前 lynxAppId 的定向 latest-bundle-list
  ├─ GET bundleUrl，校验 size/SHA-256，写入 current
  └─ POST release/report 上报检查、下载、激活和回滚结果
          │
          ▼
LynxView 加载本地 current Bundle
```

移动端只读公共 OTA API 和 OSS/CDN Bundle。发布、灰度、禁用、回滚、上传凭证等操作由
CI/CD/Admin 完成，不能把 Admin token 放入 App。

当前 Router 的默认热更路径不要求先调用 `policy/match` 或 `manifest`：

```text
启动/回前台       -> GET latest-bundle-list（全量）
页面打开/缺包修复 -> GET latest-bundle-list（指定 lynxAppId）
下载              -> GET changedBundles[].bundleUrl
结果上报          -> POST release/report
```

`policy/match` 和 `release/:releaseId/manifest` 仍由底层 OTA SDK 提供，用于灰度策略、
指定 Release 或旧客户端兼容；是否启用由宿主产品决定。

## 2. 公共 API 基础约定

假设服务端地址为：

```text
https://ota.example.com
```

除 Bundle 本身的 CDN 请求外，所有 `/api/ota/v1/*` 请求都需要：

```http
Accept: application/json
x-ota-client-token: <运行时注入的客户端令牌>
```

POST JSON 还需要：

```http
Content-Type: application/json; charset=utf-8
```

令牌只能由原生宿主从安全配置注入，不能放在 URL 查询参数、Lynx `params`、Bundle 内容、
日志或 Git 仓库中。下载 `bundleUrl` 时不要把 `x-ota-client-token` 转发给 OSS/CDN；CDN
只需要返回 Bundle 文件。

客户端当前使用约 10 秒连接超时、30 秒 API 读取超时；Bundle 下载读取超时约 15 秒。
服务端应支持 HTTPS、标准 2xx JSON 响应和幂等重试。

## 3. 移动端实际对接的接口

| 方法 | 路径 | 调用时机 | 返回 |
| --- | --- | --- | --- |
| `GET` | `/api/ota/v1/releases/latest-bundle-list` | 启动/回前台，全量 appId | `{ env, hostApp, platform, bundleLists[] }` |
| `GET` | `/api/ota/v1/releases/latest-bundle-list?lynxAppId=...` | 打开页面或缺包修复，单个 appId | 一个最新 Release 快照 |
| `GET` | `/api/ota/v1/release/{releaseId}/manifest` | 指定 Release/灰度命中后的 Manifest | Manifest（当前服务端字段名为 `bundles`） |
| `POST` | `/api/ota/v1/policy/match` | 可选的灰度/策略匹配 | `{ matched, releaseId?, manifestUrl?, ruleId? }` |
| `POST` | `/api/ota/v1/release/report` | 检查、下载、激活、打开、回滚结果 | `{ accepted, releaseId?, event? }` |
| `GET` | `changedBundles[].bundleUrl` | 下载 OSS/CDN Bundle | 二进制 `*.lynx.bundle`，不是 OTA JSON API |

### 3.1 全量 latest-bundle-list

请求：

```http
GET /api/ota/v1/releases/latest-bundle-list?env=TEST&hostApp=capp&platform=android
```

查询参数：

| 参数 | 必填 | 规则 |
| --- | --- | --- |
| `env` | 是 | `TEST`、`STAGING`、`PROD` |
| `hostApp` | 是 | 宿主 App 标识，例如 `capp` |
| `platform` | 否 | 当前服务端为 `android` 或 `ios`；不传表示服务端自行选择/聚合 |
| `lynxAppId` | 否 | 不传为全量；传入 8 位数字为定向查询 |

全量响应示例：

```json
{
  "env": "TEST",
  "hostApp": "capp",
  "platform": "android",
  "bundleLists": [
    {
      "env": "TEST",
      "hostApp": "capp",
      "lynxAppId": "10000001",
      "releaseId": "r20260629_001",
      "platform": "android",
      "platforms": ["android"],
      "status": "ACTIVE",
      "updatedAt": "2026-06-29T04:45:47.000Z",
      "minAppVersion": "1.0.0",
      "maxAppVersion": "9.9.9",
      "lynxSdkRange": { "min": "4.0.0", "max": "4.x" },
      "nativeProtocolVersionRange": { "min": "1.0.0" },
      "changedBundles": [
        {
          "pageId": 10000001,
          "bundlePath": "pages/10000001/home.lynx.bundle",
          "bundleUrl": "https://cdn.example.com/cappLynx/lynx/test/10000001/r20260629_001/home.lynx.bundle",
          "bundleSha256": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "size": 524288,
          "required": true,
          "prefetch": true
        }
      ]
    }
  ]
}
```

没有任何可用 Release 时，全量接口可以返回 `200` 和空数组 `"bundleLists": []`。客户端会
保留内置/当前版本，不应把空数组当作删除指令。

### 3.2 定向 latest-bundle-list

请求：

```http
GET /api/ota/v1/releases/latest-bundle-list?env=TEST&hostApp=capp&lynxAppId=10000001&platform=android
```

响应是单个 Release 快照，不再包一层 `bundleLists`：

```json
{
  "env": "TEST",
  "hostApp": "capp",
  "lynxAppId": "10000001",
  "releaseId": "r20260629_001",
  "platform": "android",
  "platforms": ["android"],
  "status": "ACTIVE",
  "changedBundles": [
    {
      "pageId": 10000001,
      "bundlePath": "pages/10000001/home.lynx.bundle",
      "bundleUrl": "https://cdn.example.com/cappLynx/lynx/test/10000001/r20260629_001/home.lynx.bundle",
      "bundleSha256": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "size": 524288,
      "required": true,
      "prefetch": false
    }
  ]
}
```

当前 Android、iOS、Harmony 客户端都兼容把“单个快照”包装为一项列表的读取方式，但服务端
应按上面的单对象格式返回。定向查询没有可用 Release 时，当前服务端返回 `404`。

### 3.3 `changedBundles` 字段规则

| 字段 | 必填 | 服务端类型/规则 | 客户端用途 |
| --- | --- | --- | --- |
| `pageId` | 是 | 正整数；建议与业务页面或 appId 稳定对应 | 诊断、事件上报和旧协议兼容 |
| `bundlePath` | 是 | 相对路径，必须精确指向一个 `.lynx.bundle` | 本地 current 的唯一身份；不要只返回 basename |
| `bundleUrl` | 是 | 绝对 URL；生产必须 `https://` | 下载源；当前服务端字段名就是 `bundleUrl` |
| `bundleSha256` | 是 | 推荐 `sha256:` + 64 位小写十六进制 | 下载后完整性校验 |
| `size` | 是 | 整数，`1..20971520`，单位字节 | 下载大小校验；客户端在流式传输中强制 20 MB 上限 |
| `required` | 是 | Boolean | 发布元数据；当前 Router 不改变页面打开策略 |
| `prefetch` | 是 | Boolean | 发布元数据；当前 Router 不强制后台预取 |

`bundlePath` 要求：

```text
允许：pages/10000001/home.lynx.bundle
拒绝：/data/user/0/.../home.lynx.bundle
拒绝：../home.lynx.bundle
拒绝：pages/10000001/../home.lynx.bundle
拒绝：pages/10000001/home.bundle
```

路由调用传入的是 `lynxAppId + bundleName`，例如 `10000001 + home.lynx.bundle`。客户端会
优先按 `bundlePath` 精确匹配；只有同一 appId 下 basename 唯一时才允许 basename 兼容匹配。
因此服务端必须保证同一个 `lynxAppId` 的发布快照中 Bundle basename 不重复，并且不能用
两个不同路径发布同名 Bundle。

当前服务端 Zod schema 对 `bundleSha256` 只做非空校验，对 `bundleUrl` 只做 URL 校验；这是
服务端现状，不是生产安全标准。发布前应在 Server/CI 校验 HTTPS、SHA-256 格式、文件大小和
路径安全，避免把错误数据推给客户端。

### 3.4 Manifest 接口

请求：

```http
GET /api/ota/v1/release/r20260629_001/manifest?env=TEST&hostApp=capp&lynxAppId=10000001&platform=android
```

当前服务端 Manifest 响应的 Bundle 数组字段为 `bundles`（不是 `changedBundles`）：

```json
{
  "env": "TEST",
  "hostApp": "capp",
  "lynxAppId": "10000001",
  "releaseId": "r20260629_001",
  "platform": "android",
  "platforms": ["android"],
  "status": "ACTIVE",
  "bundles": [
    {
      "pageId": 10000001,
      "bundlePath": "pages/10000001/home.lynx.bundle",
      "bundleUrl": "https://cdn.example.com/cappLynx/lynx/test/10000001/r20260629_001/home.lynx.bundle",
      "bundleSha256": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "size": 524288
    }
  ]
}
```

Manifest 的 `status` 是必填字段；客户端只允许 `ACTIVE` Release 进入下载/激活，
`DISABLED` 和 `ROLLED_BACK` 必须保留 current 并跳过本次安装。

服务端当前应返回 `bundlePath`，不能只返回 `bundleName`。`bundleName` 不是当前 Server
Manifest 的必需字段；如果将来新增该字段，也必须继续保留 `bundlePath`，直到三端客户端同时
升级完成。

### 3.5 策略匹配接口（可选）

请求：

```http
POST /api/ota/v1/policy/match
```

```json
{
  "env": "PROD",
  "hostApp": "capp",
  "lynxAppId": "10000001",
  "platform": "android",
  "appVersion": "8.2.0",
  "buildNumber": "820001",
  "osVersion": "15",
  "channel": "official",
  "region": "CN",
  "userId": "user-placeholder",
  "deviceId": "device-placeholder",
  "pageId": 10000001,
  "nativeProtocolVersion": "1.0.0",
  "lynxSdkVersion": "4.0.0"
}
```

命中：

```json
{
  "matched": true,
  "releaseId": "r20260629_001",
  "manifestUrl": "https://ota.example.com/api/ota/v1/release/r20260629_001/manifest?env=PROD&hostApp=capp&lynxAppId=10000001&platform=android",
  "ruleId": "default_active_release"
}
```

未命中：

```json
{ "matched": false }
```

服务端启用 fallback kill-switch 时可以返回：

```json
{
  "matched": false,
  "fallbackToEmbedded": true,
  "reasonCode": "fallback_override_enabled"
}
```

客户端收到未命中或 fallback 时应保留当前/内置 Bundle，不得清空可用版本。

### 3.6 事件上报接口

请求：

```http
POST /api/ota/v1/release/report
```

```json
{
  "env": "TEST",
  "hostApp": "capp",
  "lynxAppId": "10000001",
  "releaseId": "r20260629_001",
  "platform": "android",
  "event": "lynx_bundle_download_success",
  "pageId": 10000001,
  "deviceId": "device-placeholder",
  "appVersion": "8.2.0",
  "buildNumber": "820001",
  "osVersion": "15",
  "bundlePath": "pages/10000001/home.lynx.bundle",
  "bundleSha256": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "bundleSize": 524288,
  "eventStage": "DOWNLOAD",
  "eventResult": "SUCCESS",
  "latencyMs": 832
}
```

当前服务端允许的 `event`：

```text
lynx_ota_check_result
lynx_bundle_download_success
lynx_release_activate
lynx_page_open
lynx_release_rollback
```

允许的 `eventStage`：`CHECK`、`MATCH`、`MANIFEST`、`DOWNLOAD`、`ACTIVATE`、`PAGE_OPEN`、
`ROLLBACK`；`eventResult`：`SUCCESS`、`SKIPPED`、`FAILED`。

成功响应示例：

```json
{
  "accepted": true,
  "releaseId": "r20260629_001",
  "event": "lynx_bundle_download_success"
}
```

当前服务端 report schema 不接收 `bundleName` 作为正式字段；请使用 `bundlePath`。如果
需要记录 Bundle 文件名，服务端可以从 `bundlePath` 派生，或后续统一升级三端和 Server schema。

### 3.7 Bundle 下载接口

客户端直接请求 `changedBundles[].bundleUrl`，例如：

```http
GET https://cdn.example.com/cappLynx/lynx/test/10000001/r20260629_001/home.lynx.bundle
```

CDN/OSS 应返回：

- `2xx` 状态码和非空二进制内容；
- 与 `size` 一致的字节数；
- 与 `bundleSha256` 一致的 SHA-256；
- 生产使用 HTTPS；
- 不依赖 `x-ota-client-token`，也不要把 API token 透传到 CDN。

当前 Router 不要求 OSS Host 白名单，但仍会拒绝非 HTTPS、非 2xx、空响应、超过 20 MB 或
SHA-256 不匹配的内容。服务器和 CDN 可以使用任意受信任域名，只要满足这些资源契约。

## 4. 错误响应与客户端行为

| HTTP | 当前服务端响应示例 | 客户端处理 |
| ---: | --- | --- |
| `200` | JSON 成功响应 | 解析、校验并继续事务 |
| `400` | `{ "message": "...参数不合法", "issues": ... }` | 记录参数错误，保留当前/内置 Bundle |
| `401` | `{ "message": "客户端令牌无效或缺失" }` | 不重试无效令牌，交给宿主修正配置 |
| `404` | `{ "message": "最新发布 bundle-list 不存在" }` 或 `manifest 不存在` | 目标无可用 Release，继续使用当前/内置版本 |
| `429` | `{ "message": "客户端请求过于频繁，请稍后重试" }`，可能带 `Retry-After` | 遵守 `Retry-After`，不得忙循环重试 |
| `5xx`/网络失败 | 服务端错误或连接失败 | 页面优先打开本地有效版本；缺包时显示 Loading/失败重试 |

服务端不要用 `200` 包装业务失败并把错误塞进另一个自定义字段；客户端按 HTTP 状态和 JSON
字段处理，便于三端一致。

## 5. CI/CD 和 Admin 的发布输入

发布系统至少需要为每个 `lynxAppId`、每个 Release 保存：

```json
{
  "env": "TEST",
  "hostApp": "capp",
  "lynxAppId": "10000001",
  "platforms": ["android", "ios"],
  "releaseId": "r20260629_001",
  "changedBundles": [
    {
      "pageId": 10000001,
      "bundlePath": "pages/10000001/home.lynx.bundle",
      "bundleUrl": "https://cdn.example.com/cappLynx/lynx/test/10000001/r20260629_001/home.lynx.bundle",
      "bundleSha256": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "size": 524288,
      "required": true,
      "prefetch": true
    }
  ]
}
```

CI/CD 的顺序应是：生成 Bundle → 上传 OSS/CDN → 下载回读 → 校验 SHA/size → 创建 Release
→ 发布 `ACTIVE` → 移动端才可从 latest 接口读到。发布失败时不能提前把半成品写成 current。

`/api/admin/ota/**` 下的创建、发布、灰度、禁用、上传凭证和指标查询是后台接口；移动端
Router 不调用这些接口。后台鉴权和 CI token 只能留在服务端流水线环境。

## 6. HarmonyOS 当前兼容状态

当前 `LynxOtaServer` 的平台枚举仍是 `android | ios`，而 Harmony 客户端的本地平台是
`harmony`。在 Server 正式支持 Harmony 前，Demo 可以用客户端配置
`serverPlatform=android` 临时读取 Android Release；这不是服务端已经支持 Harmony 的证明。

要正式支持 Harmony，服务端至少需要同步放开以下 schema、查询和指标字段：

```text
platform: android | ios | harmony
publish.platforms
release.platforms
policy.match.platform
metrics.report.platform
fallback policy.platform
```

完成服务端升级后，移除客户端的 `serverPlatform=android` 兼容配置，并用
`platform=harmony` 做一次真实发布、定向查询、下载、校验和上报验收。

## 7. 服务端联调验收清单

- [ ] 缺少或错误 `x-ota-client-token` 返回 `401`，不返回敏感信息。
- [ ] 全量 latest 接口返回所有可用 `lynxAppId`，无 Release 时返回空 `bundleLists`。
- [ ] 定向 latest 接口只返回目标 `lynxAppId`，不存在时返回 `404`。
- [ ] `hostApp`、`lynxAppId`、`releaseId`、`platform` 在响应中保持一致。
- [ ] 每个 Bundle 同时有 `bundlePath`、`bundleUrl`、`bundleSha256`、`size`；路径无穿越，URL 为 HTTPS。
- [ ] 从 `bundleUrl` 下载的字节数和 SHA-256 与 Manifest 完全一致。
- [ ] `policy/match` 的命中、未命中、fallback 三种响应都可被客户端解析。
- [ ] `release/report` 接受成功/失败/跳过事件，并返回 `accepted: true`。
- [ ] 限流返回 `429` 和可选 `Retry-After`，客户端不会忙循环。
- [ ] Release 未发布、Bundle 下载失败或校验失败时，客户端仍可使用当前/内置 Bundle。
- [ ] Admin/CI token 不出现在 App、Bundle、README、日志和 CDN URL 中。
