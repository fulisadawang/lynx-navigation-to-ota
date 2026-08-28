# Lynx Bundle 版本可见性测试用例

更新时间：2026-08-23

## 测试目标

验证用户在手机屏幕上可以明确区分：

1. 当前加载的是哪个内置 Bundle 版本；
2. OTA 热更新完成后，当前加载的是哪个远程 Bundle 版本；
3. 远程版本首屏失败回滚后，当前又回到了哪个版本。

只看 `logcat`、Xcode 日志、设备目录或 state 文件，不算满足本测试。版本信息必须在手机页面上可见。

## 页面版本卡片（已接入）

当前 Playground 首页已经接入固定位置的“Bundle 版本卡片”；OTA Demo 页面也会把编译期
`LYNX_BUILD_VERSION` 显示在页面内容中：

```text
Lynx Bundle
App ID       10000001
Release      <实际 releaseId>
来源         EMBEDDED BASELINE / OTA CURRENT / ROLLBACK FALLBACK
Bundle       home.lynx.bundle
加载时间     12:03:21
```

其中：

- `App ID`：来自当前请求的 `lynxAppId`；
- `Release`：唯一版本身份，来自 Manifest/Release 的 `releaseId`；
- `来源`：必须明确区分 `EMBEDDED BASELINE`、`OTA CURRENT`、`ROLLBACK FALLBACK`；
- `Bundle`：当前实际加载的 `bundleName` 或 `bundlePath`；
- `加载时间`：只用于辅助判断，不作为版本身份；当前宿主元数据卡片优先展示 SHA，加载时间可由业务页补充。

原生 App 的 `versionName/buildNumber` 不能代替 Lynx Bundle 的 `releaseId`。用户要确认的是 Bundle 版本，而不是原生 APK/IPA/HAP 版本。

## 版本信息来源契约

```text
Android
  PreparedActivityBundle.releaseId
  PreparedActivityBundle.lynxAppId
  当前来源由 Runtime 标记为 embedded / downloaded / rollback

iOS
  PreparedOtaBundle.releaseId
  PreparedOtaBundle.lynxAppId
  当前来源由 Runtime 标记为 embedded / current / rollback

HarmonyOS
  PreparedPageBundle.releaseId
  PreparedPageBundle.lynxAppId
  当前来源由 Runtime 标记为 rawfile baseline / downloaded / rollback
```

版本卡片应由宿主注入这些已解析的元数据，不能让 Lynx 页面自行猜目录或读取绝对路径。

## TC-01：首次安装读取内置 baseline

### 前置条件

- 已使用构建期脚本把服务端返回的 baseline 写入目标平台资源；
- 设备没有该 App 的远程 current，或使用新安装/清除数据后的 App；
- 页面版本卡片已经接入；如果测试的是原生 Tab，卡片来源应显示 `Tab cache-only`。

### 步骤

1. 安装 APK/IPA/HAP。
2. 冷启动 App。
3. 打开目标 Lynx 页面。
4. 查看页面版本卡片。

### 预期

- 页面正常打开；
- `来源 = EMBEDDED BASELINE`；
- `App ID` 与资源 Manifest 一致；
- `Release` 与 `embedded-bundles.json` 中对应 App 的 `releaseId` 一致；
- `Bundle` 与实际打开的 `bundleName` 一致；
- Android 不出现 `files/lynx-ota-store/embedded`；
- iOS 不生成 App Bundle 的 baseline 副本；
- HarmonyOS 不生成 `filesDir/lynx-embedded`。

## TC-02：OTA 热更新后识别新版本

### 前置条件

- 服务端发布一个新的、与 baseline 不同的 Release；
- 新 Release 的 `releaseId` 必须与 baseline 不同；
- 新 Release 页面内容增加明显可视标记，例如：

```text
OTA-DEMO-V2
```

### 步骤

1. 先打开页面，记录版本卡片中的 baseline `Release`。
2. 让 App 进入后台再回前台，或重新冷启动。
3. 等待原生全量 `latest-bundle-list` 和 Bundle 校验完成。
4. 关闭页面并重新打开同一个 Lynx 页面。
5. 再查看版本卡片。

### 预期

- 当前页面可看到新的 `Release`；
- `来源 = OTA CURRENT`；
- 新旧 `Release` 明确不同；
- 页面内容出现新 Release 的可视标记；
- Android 远程文件位于 `files/lynx-ota-store/apps/<appId>/releases/<newReleaseId>/`；
- `apps/<appId>/state.json` 的 current 指向新 Release；
- 重新杀进程、重新启动后仍显示新 Release；
- 内置 baseline 没有被修改。

## TC-03：OTA 更新期间当前页面不被强制替换

### 步骤

1. 打开 baseline 页面，确认卡片显示旧 Release。
2. 在页面保持可见时触发前台同步。
3. 等待 OTA 下载和激活完成。
4. 观察当前已经打开的页面。

### 预期

- 当前已经显示的 LynxView 继续使用旧 Release，不被后台任务突然替换；
- 下次重新打开页面或冷启动后，才显示新 Release；
- 版本卡片能清楚区分“当前页面正在使用的版本”和“磁盘已经准备好的版本”。

## TC-04：首屏失败回滚到 previous 或内置 baseline

### 前置条件

- 准备一个可以稳定触发首屏失败的远程 Release；
- 失败 Release 的 `releaseId` 与当前 Release 不同；
- 页面版本卡片支持显示 `ROLLBACK FALLBACK`。

### 步骤

1. 让失败 Release 完成 OTA 激活。
2. 打开该 Lynx 页面。
3. 等待原生容器检测首屏失败。
4. 观察回滚提示和版本卡片。

### 预期

- 原生出现“正在回滚”状态；
- 如果存在可用 previous remote：
  - current 切回 previous remote；
  - 版本卡片显示 previous 的 `releaseId`；
  - 来源显示 `ROLLBACK FALLBACK` 或 `OTA PREVIOUS`；
- 如果不存在 previous remote：
  - 删除失败的 downloaded current；
  - 直接从内置 assets/rawfile/App Bundle 读取 baseline；
  - 版本卡片显示 baseline 的 `releaseId`；
  - 来源显示 `ROLLBACK FALLBACK`；
- 同一次页面生命周期最多自动回滚一次，不出现无限重试。

## TC-05：重启后版本身份保持一致

### 步骤

1. 记录 OTA 更新后页面卡片的 `App ID + Release + 来源`。
2. 强制杀掉 App 进程。
3. 重新启动并打开同一 Bundle。
4. 再次读取页面卡片。

### 预期

- `App ID` 不变；
- `Release` 不回退、不重新随机生成；
- 来源仍为 `OTA CURRENT`，除非上一次确实发生了回滚；
- 页面展示版本与 `current` state 指向一致。

## TC-06：原生 Tab 不触发重复 OTA

### 步骤

1. 启动 App 并完成一次全量 OTA 同步。
2. 进入原生 Tab 容器。
3. 在 Home/Settings 或其它 Tab 间反复切换。
4. 观察每个 Tab 的版本卡片和网络日志。

### 预期

- Tab 切换只调用 `resolveCurrent`；
- 不重新请求全量 `latest-bundle-list`；
- 不触发定向 repair；
- 每个 Tab 显示同一份已提交 current Release；
- 如果 Tab 使用内置 baseline，来源明确显示 `EMBEDDED BASELINE`；使用远程 current 时显示
  `OTA CURRENT`，不能把两者都覆盖成 `TAB CACHE`；
- `loadPolicy` 单独显示或可观测为 `cache_only`，不替代真实 `source`；
- 主动刷新成功后 Home/Settings 的页面实例重新创建并读取新 Release；刷新失败时旧实例和旧
  Release 保持不变。

## 最终通过标准

下面四个字段必须始终能在手机屏幕上看到并且可解释：

```text
lynxAppId
releaseId
source
bundleName / bundlePath
```

只满足“页面能打开”不算通过；只有用户能在页面上明确看到内置版本、OTA 版本和回滚后的版本，才算这套 OTA 流程验收完成。

## 已完成的 TEST 发布样例

`lynx-ota-demo-10000001` 已按本地 OSS + CI/CD 流水线完成一次真实 TEST 发布：

- `lynxAppId=10000001`，`platforms=android,ios`；
- `buildVersion=codex-20260823-bundle-meta-v1`；
- `releaseId=r20260823_utlakh`，状态 `ACTIVE`；
- 12 个 Bundle 在 OSS/CDN 回读均为 HTTP 200，size/SHA 校验 `12/12`；
- 页面显示构建版本，可用于手机端区分 OTA 前后内容。

### 最新 Playground 全量 Release

随后已将当前 Playground 的全部 16 个 Bundle 接入同一个完整 OTA 快照，同时保留原有
12 个 OTA Demo Bundle：

- 完整 Bundle 数量：28 个；
- `main.lynx.bundle` 的 `pageId=1117`；
- 最新 `releaseId=r20260823_qc8ffc`，状态 `ACTIVE`；
- Android/iOS latest 均回读到 28 个 Bundle；
- OSS/CDN 回读校验 `28/28`；
- Android Playground 首页已实机显示 `OTA current + r20260823_qc8ffc + main.lynx.bundle`。
