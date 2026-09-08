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
  ├─ 校验整批 selection/directives，逐 App 先提交 lastDecision
  ├─ GET bundleUrl，校验 size/SHA-256，最终守卫后提交 current
  └─ Android/iOS POST release/report；Harmony 本次不扩展完整指标系统
          │
          ▼
LynxView 加载本地 current Bundle
```

移动端只读公共 OTA API 和 OSS/CDN Bundle。发布、灰度、禁用、回滚、上传凭证等操作由
CI/CD/Admin 完成，不能把 Admin token 放入 App。

当前 Router 的默认热更路径不要求先调用 `policy/match` 或 `manifest`：

```text
启动/回前台       -> GET latest-bundle-list（全量）
页面后台检查/缺包修复 -> GET latest-bundle-list（指定 lynxAppId；Tab 普通切换不请求）
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
| `GET` | `/api/ota/v1/releases/latest-bundle-list` | 启动/回前台/身份变更，全量 appId | 新模式 `{ selectionSchemaVersion, env, hostApp, platform, bundleLists[], directives[] }` |
| `GET` | `/api/ota/v1/releases/latest-bundle-list?lynxAppId=...` | 后台检查或缺包修复，单个 appId | selected Release 或明确 decision |
| `GET` | `/api/ota/v1/release/{releaseId}/manifest` | 指定 Release/灰度命中后的 Manifest | Manifest（当前服务端字段名为 `bundles`） |
| `POST` | `/api/ota/v1/policy/match` | 可选的灰度/策略匹配 | `{ matched, releaseId?, manifestUrl?, ruleId? }` |
| `POST` | `/api/ota/v1/release/report` | 检查、下载、激活、打开、回滚结果 | `{ accepted, releaseId?, event? }` |
| `GET` | `changedBundles[].bundleUrl` | 下载 OSS/CDN Bundle | 二进制 `*.lynx.bundle`，不是 OTA JSON API |

### 3.1 全量 latest-bundle-list

请求：

```http
GET /api/ota/v1/releases/latest-bundle-list?env=TEST&hostApp=capp&platform=android&versioncode=120&lynxSdkVersion=4.0.0
```

查询参数：

| 参数 | 必填 | 规则 |
| --- | --- | --- |
| `env` | 是 | `TEST`、`STAGING`、`PROD` |
| `hostApp` | 是 | 宿主 App 标识，例如 `capp` |
| `platform` | 新模式必填 | `android`、`ios`、`harmony`；Harmony 不降级查询 Android |
| `lynxAppId` | 否 | 不传为全量；传入 8 位数字为定向查询 |
| `versioncode` | 新模式必填 | 精确小写字段，正十进制字符串 `1..9223372036854775807`，不是版本名称 |
| `lynxSdkVersion` | 新模式必填 | 实际 Runtime 的稳定数字版本，trim 后 1–3 段并补齐三段 |
| `userId` | 否 | 原生注册的用户；匿名省略。raw 控制字符先拒绝，再 trim，最大 256 UTF-8 字节 |

出现非空 userId 或任一版本字段就要求 platform/code/SDK 完整，缺失返回 400；不悄悄降级成无范围旧查询。
两个版本字段均未出现、userId 没有非空值时才走旧模式：保留只选 full 的旧结构，但有 versionCodeRange 的 Release 不向缺 code 的旧请求放行。
新版 Router 的启动、定向、repair、主动刷新都带完整上下文。注册入口为原生 `registerOtaUserId/clearOtaUserId`，不新增 JS Bridge 注册接口。

Server 先按用户灰度资格、native code/SDK/其他范围过滤，再比较不可变 releaseSequence：**full7 胜 gray6**，有资格用户的 gray8 胜 full7。
policyRevision 是 scope 策略修订，不是内容版本；高修订允许 rollback 到低 releaseSequence。两者均以十进制字符串传输，不能转浮点或直接按原始字符串字典序排序。

全量响应示例：

```json
{
  "selectionSchemaVersion": 1,
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
      "selectionSchemaVersion": 1,
      "releaseSequence": "7",
      "selection": { "kind": "full", "policyRevision": "21", "reason": "latest_full" },
      "versionCodeRange": { "min": "120", "max": "199" },
      "updatedAt": "2026-06-29T04:45:47.000Z",
      "minAppVersion": "1.0.0",
      "maxAppVersion": "9.9.9",
      "lynxSdkRange": { "min": "4.0.0", "max": "4.9.9" },
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
  ],
  "directives": []
}
```

新模式中每个枚举到的 App 必须有 selected 或 directive。无远程可用版本的 App 放入 directives，不能用空数组混淆撤销、网络失败和无更新。
空 bundleLists 本身不是删除指令；只有明确 `use_embedded/no_compatible_release` 才持久约束新入口。

### 3.2 定向 latest-bundle-list

请求：

```http
GET /api/ota/v1/releases/latest-bundle-list?env=TEST&hostApp=capp&lynxAppId=10000001&platform=android&versioncode=120&lynxSdkVersion=4.0.0
```

有选中 Release 时响应为单个快照，不包一层 bundleLists；示例：

```json
{
  "env": "TEST",
  "hostApp": "capp",
  "lynxAppId": "10000001",
  "releaseId": "r20260629_001",
  "platform": "android",
  "platforms": ["android"],
  "status": "ACTIVE",
  "selectionSchemaVersion": 1,
  "releaseSequence": "7",
  "selection": { "kind": "full", "policyRevision": "21", "reason": "latest_full" },
  "versionCodeRange": { "min": "120", "max": "199" },
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

新模式中没有可用 Release 返回 200 和明确 decision；404 仍可能来自旧模式或不存在的其他资源，不能把它当作新版撤销决定：

```json
{
  "selectionSchemaVersion": 1,
  "env": "TEST",
  "hostApp": "capp",
  "platform": "harmony",
  "decision": {
    "lynxAppId": "10000001",
    "action": "use_embedded",
    "policyRevision": "22",
    "reason": "fallback_override_enabled"
  }
}
```

全量 directives 的每项使用同一 decision 结构。另一合法 action 是 `no_compatible_release`。
有用户灰度时 selection.kind 为 gray，带 ruleId 和 reason=matched_gray；正式全量或 server rollback 不回传白名单/raw userId。
新模式缺失 selection metadata、重复 App 或非法范围时客户端拒绝，不静默归为 full。

### 3.2.1 缓存、落盘与身份屏障

新响应为 `Cache-Control: private, no-cache`；Server 先计算当前用户决定再判断 ETag，覆盖 scope/选择/revision。
客户端 cache key 隔离 audience、platform、versioncode、SDK、全量/定向 scope 和 epoch；304 仅复用同 key 已验证响应。
不得记录含 userId 的完整 query URL。Bundle URL 不附加 userId，不透传 OTA token。

State 仍为 v3，ref 携带 selection，State 原子保存 selectionSchemaVersion 和 lastDecision：audienceKey、clientContextKey、policyRevision、action、targetReleaseId。
lastDecision 不引用 bytes，不是 GC root；不建立 users 目录。unknown 旧 v3 ref 在新模式等 Server 确认，确认同包后仍可复用 CAS。
current/previous/candidate 读取均重检归属及 native/SDK 范围；Harmony 不实现 candidate。embedded 指令持久化后，冷读也不复活 remote。

整批协议先校验，再逐 App 独立提交决定，最后下载；更新失败不能跳过另一 App 的 directive。失败保留 partialResult，整批仍报告失败。
最终 State rename 前再校验捕获 epoch 与已接受决定；旧回调不能重新捕获新身份绕过屏障。Android/iOS report 也使用操作身份。
Tab 普通切换 cache-only、普通后台不重建；身份/主动刷新完成后按当前 epoch 重读 State，包括 partial failure 中已提交的成功或撤销。

### 3.3 `changedBundles` 字段规则

| 字段 | 必填 | 服务端类型/规则 | 客户端用途 |
| --- | --- | --- | --- |
| `pageId` | 是 | 正整数；建议与业务页面或 appId 稳定对应 | 诊断、事件上报和旧协议兼容 |
| `bundlePath` | 是 | 相对路径，必须精确指向一个 `.lynx.bundle` | 本地 current 的唯一身份；不要只返回 basename |
| `bundleUrl` | 是 | 绝对 URL；生产必须 `https://` | 下载源；当前服务端字段名就是 `bundleUrl` |
| `bundleSha256` | 是 | 推荐 `sha256:` + 64 位小写十六进制 | 下载后完整性校验 |
| `size` | 是 | 整数，`1..20971520`，单位字节 | 下载大小校验与 20 MB 上限；Harmony 当前仍是 ArrayBuffer 返回后校验，不冒充流式内存限制 |
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

发布前必须验证 HTTPS、SHA-256 格式、实际文件大小和路径安全；“URL 能解析”不能替代下载回读及 bytes 校验。
changedBundles 是完整目标 Manifest，不是增量 patch。100 包中只改 050，客户端只下载缺失 1、复用 99、复制 0；
有界 GC 后回滚到已回收版本也允许补缺 1，不要求无限保留历史。

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
  "versioncode": "820001",
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

普通未命中/网络失败只保留当前身份仍合法的本地版本。明确 fallback/embedded 决定必须阻断 remote 新入口，不能用旧 current 绕过撤销。

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
  "versioncode": "820001",
  "lynxSdkVersion": "4.0.0",
  "userId": "synthetic-operation-user",
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

versioncode 是独立持久化字段，不覆盖 buildNumber。Android/iOS 上报使用触发操作时捕获的身份；
用户切换后迟到事件不能改标为新用户，诊断文本不输出 raw userId、URL 或异常 body。Harmony 本次仅接选择协议，不宣称已有完整指标上报。

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
| `404` | 旧模式 latest 或 manifest 等资源不存在 | 仅保留当前身份可用的本地回退；新版成功撤销用 200 decision 表达 |
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
  "platforms": ["android", "ios", "harmony"],
  "platformVersionCodeRanges": {
    "android": { "min": "120", "max": "199" },
    "ios": { "min": "800", "max": "899" },
    "harmony": { "min": "20", "max": "29" }
  },
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

Release 创建时由 scope counter 事务分配不可变正 releaseSequence；发布、规则/状态、rollback/fallback 在同 scope 事务内递增 policyRevision。
禁止 MAX+1 竞态或用时间戳代替修订。平台构建码范围须完整保存，查询时才按请求平台输出有效 versionCodeRange，不能在创建时折叠为 platforms[0]。
原生 versioncode 来源分别为 Android PackageInfo、iOS 整数 CFBundleVersion/显式覆盖、Harmony 自身 BundleInfo；
SDK 来源分别为 resolved-variant BuildConfig、可信 Lynx 资源/framework metadata、真实 LynxEnv HAR getter。详见 [Module 接入](MODULE_INTEGRATION.md#ota-用户注册版本来源与本地选择)。

`/api/admin/ota/**` 下的创建、发布、灰度、禁用、上传凭证和指标查询是后台接口；移动端
Router 不调用这些接口。后台鉴权和 CI token 只能留在服务端流水线环境。

## 6. HarmonyOS 与匿名内置下载

Server/Contracts 已支持 harmony 的创建、发布、查询、范围、存储与指标平台枚举；客户端固定使用 harmony，不允许 serverPlatform 降级。
统一平台覆盖：

```text
platform: android | ios | harmony
publish.platforms
release.platforms
policy.match.platform
metrics.report.platform
fallback policy.platform
```

Harmony 没有 candidate/trial；显式 captured context 贯穿 HTTP/Store/commit，旧 lease.close 不因 epoch 失效被禁止。
本次 [Harmony报告](docs/harmony-ota-user-gray-test-report.html) 对应host-final3 mode=all 18/18（5真实HTTP）＋Core25/25，0失败/跳过；release HAR/App和静态90/0/0通过。设备按用户要求未验收，不用历史v3 HDC记录替代。

Server本地最终门禁：`scripts/verify-local-contracts.mjs` 使用实际 npm pack Contracts 产物联编，125/125、0 skipped。
独立Server仓的 `scripts/backfill-release-sequences.mjs` 只预览 createdAt/releaseId 历史排序，没有apply模式、不加载.env，要求显式loopback测试库。
本次只读预览为44 scopes/372条本地记录，不能据此重排已有不可变releaseSequence。没有npm发布、远程DB操作或部署；这些验证不代表生产迁移已执行。

三端匿名内置下载命令见 [Module 接入](MODULE_INTEGRATION.md#三端匿名内置-baseline-下载)。
共用脚本必须提供 `--versioncode`、`--lynx-sdk-version`，target/platform 必须相同，始终省略 userId，只允许兼容 full；不能把个人 gray 内置进原生包。

## 7. 服务端联调验收清单

- [ ] 缺少或错误 `x-ota-client-token` 返回 `401`，不返回敏感信息。
- [ ] 新模式全量对枚举到的每个 App 返回 selected 或 directive，不用空列表表达撤销。
- [ ] 新模式定向只返回目标 selected 或 200 decision；旧模式 404 与新决定分开处理。
- [ ] full7 胜 gray6；高 policyRevision 回滚低 releaseSequence；三参数缺失/边界、Harmony 与平台独立范围通过。
- [ ] `hostApp`、`lynxAppId`、`releaseId`、`platform` 在响应中保持一致。
- [ ] 每个 Bundle 同时有 `bundlePath`、`bundleUrl`、`bundleSha256`、`size`；路径无穿越，URL 为 HTTPS。
- [ ] 从 `bundleUrl` 下载的字节数和 SHA-256 与 Manifest 完全一致。
- [ ] `policy/match` 的命中、未命中、fallback 三种响应都可被客户端解析。
- [ ] `release/report` 接受成功/失败/跳过事件，并返回 `accepted: true`。
- [ ] 限流返回 `429` 和可选 `Retry-After`，客户端不会忙循环。
- [ ] 未发布、下载/校验失败只保留当前身份适用的 current/full previous/embedded；明确 directive 在冷读仍生效。
- [ ] Admin/CI token 不出现在 App、Bundle、README、日志和 CDN URL 中。
