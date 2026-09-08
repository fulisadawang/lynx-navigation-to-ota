# OTA 用户灰度：真实 Server 本地 100 Bundle Fixture

本目录为 P05F 测试工具。`server.mjs` 动态加载独立 LynxOtaServer 编译产物导出的 `createApp()`；管理数据通过 `app.inject()` 建立，公共 OTA 请求原样交给真实 Server。这里不实现版本选择算法。所有数据库、Redis、Webhook、OSS 和签名环境配置在创建 App 前清空，fixture 只使用内存数据库及明确的合成本地认证值。

适配器只监听 `127.0.0.1`，外部不能调用管理 API。`/_fixture/*` 需要 `x-ota-fixture-control: local-fixture-only`，且拒绝不同 Origin。附带 CLI 自动设置此 header。控制接口只用于本地测试，不可用于对外部署。

## 准备和启动

先在 Server 仓执行已有隔离构建工具，使用输出 JSON 中 `sandbox` 下的 `dist/app.js`：

```sh
node scripts/verify-local-contracts.mjs /absolute/LynxContracts/packages/shared --build-only
```

在本客户端仓根目录执行：

```sh
# 默认读取已有 Playground Golden Fixture，复用 99 个真实编译包。
# 独立 Rspeedy 配置只编译 full5/gray6/full7/gray8 四个 050 标记页。
node playground/scripts/generate-ota-user-gray-fixture.mjs

# 已生成的产物仅校验即可；生成器不覆盖已有输出目录。
node playground/scripts/generate-ota-user-gray-fixture.mjs --verify

node scripts/ota-user-gray/selftest.mjs --server-module /absolute/server-sandbox/dist/app.js

node scripts/ota-user-gray/server.mjs \
  --server-module /absolute/server-sandbox/dist/app.js \
  --port 18766 \
  --bundle-origin http://127.0.0.1:18766
```

生成器支持 `--base-fixture DIR` 和 `--output DIR`。默认产物放在本目录被 Git 忽略的 `.generated/fixture/`，独立编译源码和产物保留在 `.generated/build-*/` 供核查；不构建完整 Playground，不改 Android/iOS/Harmony 常规内置资源。若默认基础 fixture 不存在，先用已有 `playground/scripts/generate-ota-store-v3-fixture.mjs --output <新目录>` 生成，再把该目录传给 `--base-fixture`。

Harmony 模拟器需要宿主映射地址时，将 Bundle origin 改为 `http://10.0.2.2:18766`；adapter 仍绑定宿主 loopback。iOS 或已配置 adb reverse 的设备使用 `127.0.0.1`。本工具不创建 reverse、不启动或安装设备。

## 客户端配置

| 字段 | 值 |
|---|---|
| API origin | `http://127.0.0.1:18766`，模拟器按对应宿主映射配置 |
| OTA client token | `ota-user-gray-local-client-token`，仅合成本地测试值 |
| env / hostApp / lynxAppId | `TEST` / `capp` / `10000001` |
| bundleName | `pages/10000001/bundle-050.lynx.bundle` |
| 灰度用户 A / 非灰度用户 B | `user_demo_A` / `user_demo_B` |
| 匿名 | 不发送 userId |
| versionCode / HTTP versioncode | `150`；全部三端的兼容范围为 `1..999` |
| lynxSdkVersion | `4.0.0`；fixture SDK 范围固定 `4.0.0..4.0.0` |

启动先禁用此 App 的内存种子发布和规则，防止不兼容时误选旧种子。通过真实 Server 按顺序创建四个 Release；不手工分配 releaseId/releaseSequence。`full5` 等仅是设计别名，实际序号不必等于别名中的数字。`/_fixture/state` 的 `actualReleaseIds`、`actualReleaseSequences` 与 `aliases` 给出真实映射。初始化只发布 full5，其余为草稿。state 和 stage/reset 控制响应都提供 `expectedReleaseId`（A 的选择）及 `expectedReleaseIds: {A,B,anonymous}`，由真实 Server 以 `ios/150/4.0.0` 查询得到；指令结果对应 null，详情在 `expectedSelections`，不是按阶段名字推断。控制查询不计入 SDK HTTP 指标。

每个 Release 都有完整 100 Bundle 快照。四个版本只有 050 的 bytes/SHA 变化，其余 99 个对象原样复用；磁盘共 103 个对象。050 页面分别编译 `FULL5-050`、`GRAY6-050`、`FULL7-050`、`GRAY8-050` 可见标记；其他 99 页保留基础 V1 的页号标记以保证字节不变。编译和 SHA 校验不等于设备渲染验收。

## 阶段和控制

```sh
node scripts/ota-user-gray/control.mjs state
node scripts/ota-user-gray/control.mjs stage '{"stage":"gray6"}'
node scripts/ota-user-gray/control.mjs stage '{"stage":"full7"}'
node scripts/ota-user-gray/control.mjs stage '{"stage":"gray8"}'

node scripts/ota-user-gray/control.mjs rule '{"alias":"gray8","enabled":false}'
node scripts/ota-user-gray/control.mjs rule '{"alias":"gray8","enabled":true}'

# 同一 releaseId 灰度转全量，必须更新 selection/ETag，但不需要新 Bundle bytes。
node scripts/ota-user-gray/control.mjs publish '{"alias":"gray8","type":"full"}'

node scripts/ota-user-gray/control.mjs fallback '{"enabled":true,"platforms":["ios"]}'
node scripts/ota-user-gray/control.mjs fallback '{"enabled":false,"platforms":["ios"]}'
node scripts/ota-user-gray/control.mjs rollback '{"from":"gray8","target":"full5"}'
node scripts/ota-user-gray/control.mjs rollback '{"from":"full5","target":"embedded"}'

node scripts/ota-user-gray/control.mjs metrics
# 只清零指标，保留发布阶段。
node scripts/ota-user-gray/control.mjs metrics-reset
# POST /_fixture/reset：重建内存数据库，回到 full5 并清零指标、fallback 和延迟。
node scripts/ota-user-gray/control.mjs reset
```

CLI 支持前置 `--origin http://127.0.0.1:<port>`。阶段仅向前推进；指定后面的阶段会顺序发布中间阶段。`reset` 或重新启动 adapter 可以获得全新内存数据库并回到 full5。reset 会取消已暂停的 HTTP 响应，准备完成后返回新 state；适合每个 UI 测试启动 SDK 前调用，不负责清理设备端缓存。规则、fallback 和回滚控制直接调用真实管理接口，其行为遵循当前 Server 契约；不在 fixture 中强行改写响应。

| 阶段 | A | B / 匿名 |
|---|---|---|
| full5 | full5 | full5 |
| gray6 | gray6 | full5 |
| full7 | full7 | full7 |
| gray8 | gray8 | full7 |

## 暂停旧 A 响应

```sh
# 仅捕获随后第一个 A latest；milliseconds=0 等待手动释放，60 秒自动兜底。
node scripts/ota-user-gray/control.mjs delay '{"audience":"A","count":1,"milliseconds":0}'
node scripts/ota-user-gray/control.mjs state
# 等 state.delay.pending 出现 captured:true 后，宿主切换 B 并完成同步。
node scripts/ota-user-gray/control.mjs release
```

暂停发生在真实 Server 已完成选择、响应和 ETag 已被捕获之后。因此 B 或新发布可以先完成，再交付旧 A 响应。`milliseconds=1..30000` 支持定时延迟。这里只提供可复现的响应顺序，SDK 对 epoch 的拒绝必须由客户端测试证明。

## 指标和证据边界

`GET /_fixture/metrics` 记录实际代理请求与实际 Bundle HTTP 响应：`latestRequestCount`、`latestCompletedCount`、`manifestRequestCount`、`reportRequestCount`、`bundleRequestCount`、`bundleSuccessCount`、`bundleBytes`、`pendingLatestCount`。Bundle 字节数只累计成功 GET 的完整响应；HEAD 不累计。控制/初始化请求不进入 OTA 计数。记录仅含 `A/B/anonymous/other` 标签、固定路径和发布别名，不保存原始 userId、Query URL 或 token。针对 `TEST/capp/10000001`（或其全量请求）且身份为已知 A/B/匿名的 latest，`requests[]` 额外记录字符串 `versioncode` 与 `lynxSdkVersion`，使用被测 Server 消费的契约 helpers 规范化，例如 `000150` → `150`、`4` → `4.0.0`。缺失、重复或非法版本字段省略，非 fixture 身份不记录版本上下文。

10 个自测使用真实编译的 Server 和 localhost HTTP，验证参数与指标规范化、身份/令牌脱敏、阶段选择、包含端点的兼容范围、ETag、规则/回退、延迟、reset 和控制限制。传输测试首次实际 GET 100 个 Bundle，随后每阶段实际 GET 1 个；同包 gray→full 实际 GET 0 个。结果写入 `.generated/fixture/transport-selftest-evidence.json`。自测中的下载去重由 SHA Set 模拟，不将其称为 Native Store、磁盘 CAS、原生 Tab 或真实设备验证。

## P06 Android Debug Demo / ADB runner

`android-device.mjs` 默认仅输出计划，`--self-test` 仅运行宿主 Node 的 XML/状态解析断言。以下两条都不访问 ADB：

```sh
node scripts/ota-user-gray/android-device.mjs --plan
node scripts/ota-user-gray/android-device.mjs --self-test
```

Android 构建、APK 安装与首次设备执行由主线程调度。验收 Debug 构建环境：

```text
LYNX_TEST_OTA_USER_SELECTION=1
LYNX_OTA_LOCAL_SERVER=1
LYNX_OTA_LOCAL_BASE_URL=http://127.0.0.1:18770
```

该模式的 Debug client token 强制使用 fixture 合成值。默认真实 APK versionCode 仍为 1；构建升级测试 APK 时增加 `LYNX_OTA_DEBUG_VERSION_CODE=1000`，只影响 Debug variant。Demo 不设置 versioncode Query 覆盖，不覆盖 Module 解析出的实际 SDK 依赖版本。没有新增 instrumentation 或 TabBar 依赖，底部沿用 Sample 的 `BottomNavigationView` 与 `LynxTabFragment`。

主线程安装 APK 并明确允许后，才运行如下设备命令：

```sh
node scripts/ota-user-gray/android-device.mjs --execute \
  --serial emulator-5554 --origin http://127.0.0.1:18770 --reverse \
  --flow all --output scripts/ota-user-gray/.generated/android-p06
```

脚本不会构建、安装 APK、执行 `pm clear`、修改普通 Store 或覆盖 embedded assets。`--reverse` 仅为给定 fixture 端口建立反向映射；若主线程已配置，可省略。所有点击先读取 UIAutomator XML，再从唯一目标节点的 bounds 计算中心坐标，不猜截图坐标。

四组共 19 个场景：core 8、policy 5、candidate 4、native 2。正常 versionCode=1 阶段可执行其中 17 个；两个真实升级场景记录 `BLOCKED_NEEDS_APK_1000`，退出码 2。主线程安装同包名 versionCode=1000 的 APK 后，保留输出目录续跑：

```sh
node scripts/ota-user-gray/android-device.mjs --execute \
  --serial emulator-5554 --origin http://127.0.0.1:18770 \
  --flow upgrade --output scripts/ota-user-gray/.generated/android-p06
```

也可单独运行 `--flow core|policy|candidate|native`。候选流程通过原生 CheckBox 持久化“下次启动模式”，保留同一 Store 冷启动，再独立打开 050；必须看到 Activity 的 `state=ready`、`promoted=true`，并从真实 `state.json` 读取目标 current 后才记 PASS。Fragment 使用 `instance/load/render/error/release/source/kind/sequence/epoch` 分号描述；切 Tab 验证 Fragment 和 load/render 计数全部稳定且 latest=0。

Demo 将身份仅存为 `A/B/anonymous` 枚举，位于独立 `ota_user_gray_demo` prefs。ADB bootstrap 仅写 `files/ota-user-gray-test/bootstrap.json`，在 Router 安装前消费并映射为合成身份。Store 为 `files/ota-user-gray-test/stores/<nativeStoreId>`；每个基础流程用新的合成 ID，冷启动/升级复用原 ID。Demo 对照 `LynxRouter.otaStorageSnapshot().rootPath` 验证实际 Store 根目录，报告不会只把配置路径当作真实存储证据。

每个实际通过场景输出 PNG、原始 UI XML、metrics、Server state、Demo 状态、私有 Store state 和对象列表；汇总为 `android-device-report.json`。未执行场景保持 PLANNED，缺少 APK 1000 保持 BLOCKED，失败保留实际错误，不生成虚构设备结果。运行前不要将宿主 Node 自检通过当作 APK 构建或设备验收通过。
