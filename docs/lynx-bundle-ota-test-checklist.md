# Lynx 三端 Bundle / OTA 流程验收清单

更新时间：2026-08-23

这份清单对应当前代码状态：内置 baseline 直接读取，远程 OTA 才写入私有 Store；App ID、Release 和 Bundle 列表均来自全量 `latest-bundle-list` 响应。

## 当前同步结果

| 平台 | 服务端查询 platform | 内置 Bundle | 资源目录 |
| --- | --- | ---: | --- |
| Android | `android` | 2 个 App / 24 个 Bundle | `android/app/src/main/assets/bundles/lynx` |
| iOS | `ios` | 3 个 App / 31 个 Bundle | `ios/LynxShellSample/Resources/Bundles/lynx` |
| HarmonyOS | `android` 兼容值 | 2 个 App / 24 个 Bundle | `harmony/lynx_shell/src/main/resources/rawfile/bundles/lynx` |

HarmonyOS 当前服务端尚未开放 `platform=harmony`，Demo 的 `serverPlatform=android` 是明确的兼容配置，不代表 Harmony 端代码把平台写成 Android。

## TEST CI/CD 实跑结果

已使用 `lynx-ota-demo-10000001` 的真实本地流水线完成一次 TEST 发布：

```text
rspeedy build
  -> ali-oss 上传变化 Bundle
  -> 拉取最新全量 bundle-list，按 bundlePath 复用 pageId
  -> 生成 bundle-list.json
  -> create release
  -> validate
  -> full publish
```

- App ID：`10000001`；平台：`android`、`ios`。
- 构建版本：`codex-20260823-bundle-meta-v1`。
- Release：`r20260823_utlakh`，服务端 latest 状态 `ACTIVE`。
- Bundle：12 个；OSS/CDN 回读校验 `12/12`。
- CI token 只调用创建/校验/发布接口；二进制由本地受保护 OSS 配置上传。
- 不使用 `upload-ticket`；当前 OTA Server 没有直接接收 Bundle 二进制的 CI API。

### 最新 Playground 全量发布

当前 Playground 的 16 个 Bundle 已全部上传并追加到 `10000001` 的完整快照中，同时保留
原 OTA Demo 的 12 个 Bundle：

- 最新 Release：`r20260823_qc8ffc`；
- 完整快照：28 个 Bundle；
- `main.lynx.bundle`：`pageId=1117`；
- Android/iOS latest：均为 `ACTIVE`、28 个 Bundle；
- CDN 回读：28/28 size + SHA-256 通过；
- Playground 内部本地 Bundle 导航已自动携带 `lynxAppId=10000001` 和对应 `bundleName`，不再走纯 Assets 直读。

## 1. 构建期 baseline 同步

Token 只从本机环境变量读取，不写脚本、文档或 Git：

```bash
export LYNX_OTA_CLIENT_TOKEN='<本机临时注入>'
BASE_URL='https://lynx-ota-server.test.huangbaoche.com'
```

分别执行：

```bash
node android/app/scripts/sync_ota_bundles_to_assets.mjs \
  --base-url "$BASE_URL" \
  --env TEST \
  --host-app capp \
  --target android \
  --platform android

node android/app/scripts/sync_ota_bundles_to_assets.mjs \
  --base-url "$BASE_URL" \
  --env TEST \
  --host-app capp \
  --target ios \
  --platform ios

node android/app/scripts/sync_ota_bundles_to_assets.mjs \
  --base-url "$BASE_URL" \
  --env TEST \
  --host-app capp \
  --target harmony \
  --platform android
```

先做 dry-run：

```bash
node android/app/scripts/sync_ota_bundles_to_assets.mjs ... --dry-run
```

预期：所有 Bundle 完成 HTTPS、size、SHA-256 校验后才替换目标资源目录；返回 HTML、非 JSON 或校验失败时，资源目录不变。

## 2. Android 验收

### 内置 baseline

- [ ] APK 包含 `assets/bundles/lynx/embedded-bundles.json`。
- [ ] `lynxAppId`、`releaseId`、`bundlePath` 与服务端同步结果一致。
- [ ] 首次打开无远程 current 时，页面可以直接从 APK assets 加载。
- [ ] Android 不生成 `files/lynx-ota-store/embedded`。

### 远程更新

- [ ] `Application.onCreate` 触发 `LynxRouter.install`。
- [ ] 启动/回前台触发 `LynxRouter.onApplicationForeground()`。
- [ ] 原生调用 `OtaSdk.syncLatestBundleLists()`，一次处理全量 App ID。
- [ ] 远程 Bundle 写入 `files/lynx-ota-store/releases/<releaseId>/`。
- [ ] `states/<appId>.json` 最后原子提交 current/previous。
- [ ] 下次打开优先读取远程 current。

### 回滚

- [ ] 制造一个首屏加载失败的远程版本。
- [ ] 页面出现原生“正在回滚”状态。
- [ ] 有 previous remote 时恢复 previous。
- [ ] 没有 previous remote 时删除坏的 downloaded current。
- [ ] 删除后重新从 APK assets 读取 baseline。
- [ ] 同一页面生命周期内不会无限回滚。

### Tab

- [ ] 切换原生 Tab 不重新请求全量接口。
- [ ] Tab 只调用 `resolveCurrent`。
- [ ] 没有 current 时读取内置 baseline，不触发 repair。
- [ ] 启动/回前台的后台全量同步不会强制替换当前已经显示的 Tab 实例。
- [ ] 后台同步完成后，下一次新建 Tab Host/冷启动会读取已提交的新 current。
- [ ] 用户点击“刷新 OTA 后重载 Tab”时，先完成全量同步，再销毁旧 LynxView 并重新读取 current。

### Android 原生 Tab Demo 回归记录（2026-08-23）

- 根因：`NativeTabDemoActivity` 的两个 `LynxTabSpec` 只有 `assets://` 兜底地址，缺少
  `lynxAppId=10000001` 和 `bundleName=main.lynx.bundle`，因此没有进入 OTA cache-only
  `resolveCurrent` 分支。
- 修复：两个 Fragment 都声明同一个 OTA Bundle 身份；切 Tab 仍只读取本地 current/baseline，
  不新增网络请求。
- 主动刷新：Demo 顶部按钮显式调用全量 OTA 同步；同步成功后两个 Fragment 都调用
  `refreshFromCurrent()`，不会在普通 Tab 切换时联网。
- Android Debug 构建通过；真机 `a7e90f03` 已验证 Home 与 Settings 两个 Fragment 均可展示，
  Home 页面显示 `10000001 / r20260823_qc8ffc / OTA current / main.lynx.bundle`。
- 切换过程中若点到内容列表，会打开对应的 Lynx 子页面；这属于页面自身点击，不是原生 Tab
  承载失败。原生底部导航点击区域可正常在 Home/Settings 间切换。

### 转场与官方 Bundle 的加载边界（2026-08-23）

- Playground 的 `bottomSheet` / `heroSheet` 目标 Bundle 是本地 OTA 身份，路由日志确认带有
  `lynxAppId=10000001` 和 `bundleName=transition-detail.lynx.bundle`。
- Android 容器先调用 cache-only `resolveCurrent()`；命中 current/baseline 时直接创建 LynxView，
  不显示 OTA Loading；命中远程 current 后由普通页面在后台按 App ID 30 分钟门控检查，
  不阻塞转场。真机已复测 BottomSheet 与 HeroSheet 均可直接进入目标内容。
- `go-bundles.lynx.bundle` 列表本身是本地 OTA Bundle；列表中的 565 个官方示例是
  `https://go.lynxjs.org/lynx-examples/...` Direct Remote，不在本地 manifest。远程路径不能
  携带 appId；远程下载期间由容器显示远程 Bundle Loading。若需要离线，必须单独纳入 OTA 清单。

真机检查命令：

```bash
adb shell run-as <package> find files/lynx-ota-store -maxdepth 3 -type f | sort
```

正常情况下可以看到 `releases/`、`states/`、`.staging/`，不应该新增 `embedded/`。

## 3. iOS 验收

- [ ] `Bundles/lynx/embedded-bundles.json` 包含服务端返回的 App ID。
- [ ] 内置 Bundle 从 App Bundle file URL 读取，不复制到 Application Support。
- [ ] `Application Support/lynx-ota-store/releases/` 只保存远程 OTA。
- [ ] iOS Simulator 可以打开 Manifest 中第一条内置 Bundle。
- [ ] OTA 配置完整时，启动/前台触发全量同步。
- [ ] current 命中时优先读 current，首屏失败时回滚到 previous 或内置 baseline。

当前构建验证：`LynxShell` iOS Simulator build 通过。

## 4. HarmonyOS 验收

- [x] rawfile Manifest 包含 `10000001/home.lynx.bundle` 与 `10000001/main.lynx.bundle`；静态门禁
  全量校验 Manifest 身份、文件 size 和 SHA。
- [x] rawfile 直接读取为 `ArrayBuffer`，不写 `filesDir/lynx-embedded`。
- [x] 远程 OTA 只写入 `<context.filesDir>/lynx-ota-store/releases/`。
- [x] Harmony 使用 `serverPlatform=android` 查询当前测试服务端，宿主 GlobalProps 仍报告 harmony。
- [x] 冷启动默认按 Manifest 身份打开 `10000001/home.lynx.bundle`；Playground 和两个 ArkUI Tab
  都按 Manifest 身份打开 `10000001/main.lynx.bundle`，不依赖 Manifest 条目顺序。
- [x] ArkUI Tab 只调用 `resolveCurrent`；真实来源保留为 `ota_current/embedded_baseline`，并单独
  注入 `loadPolicy=cache_only`。
- [x] 用户主动刷新会等待全量 OTA 完成；成功后通过 `refreshGeneration` 重建两个 LynxView，
  失败继续保留当前版本。普通 Tab 切换不修改 generation。
- [x] previous 不可用但存在 rawfile baseline 时，删除坏 downloaded current 并回到 baseline。
- [x] `assembleHar` 与 `assembleApp` 在当前 checkout 构建成功。
- [x] Pura 90 / HarmonyOS 6.1.1(24) 模拟器冷启动显示
  `10000001 / home.lynx.bundle`，Home Tab 显示
  `10000001 / r20260823_qc8ffc / embedded baseline / main.lynx.bundle`，Settings 页面正常。
- [x] Home/Settings 普通往返前后 OTA 全量同步日志计数保持 `3 → 3`，没有因切换 Tab 新增同步。
- [x] 主动刷新失败后提示“保留当前 Tab 版本”，Home/Settings 和 baseline Release 继续可用。
- [ ] 网络恢复后验证主动刷新成功、Tab 重建读取 remote current、previous/embedded rollback。

当前验证边界：Harmony 静态检查 `80 PASS / 0 WARN / 0 FAIL`，HAR 与完整 App 构建成功；
模拟器 baseline、Home/Settings 与刷新失败保留旧实例已通过。测试 OTA 域名当前在本机 `curl`
和模拟器 HTTP Client 均连接失败，因此 remote current、刷新成功和回滚运行态仍标 `[待确认]`。

## 路径速查

```text
内置：
APK assets / iOS App Bundle / Harmony rawfile
    ↓ 直接读取 + size/SHA 校验
LynxView

远程：
latest-bundle-list
    ↓ 下载
<private files>/lynx-ota-store/releases/<releaseId>/
    ↓ 原子提交
states/<appId>.json -> current / previous
```

详细交互说明见：[lynx-bundle-paths.html](./lynx-bundle-paths.html)。
