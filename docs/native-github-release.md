# 三端原生 SDK 的 GitHub 发布与消费

本轮配置位于 `codex/native-github-release`，以 `05b45a4` 为源码基线。当前自有 SDK 版本为 **1.1.0**，发行 tag 为 **native-v1.1.0**；Lynx 和 Gfx 固定 4.1.0，PrimJS 固定 4.1.1。仓库旧 `v1.0.0` Release 保留，此流程不覆盖它。

这是发布配置与源码审查交付。尚未执行 Gradle、Pod lint、Hvigor、远程安装或发布。下面的命令是操作说明，没有在本轮运行。CI 构建通过也不等于真机、UI、性能或 OTA 业务验收通过。

## 版本维护

唯一维护入口是根 `native-release.json` 与版本命令：

```bash
python3 scripts/native_release.py set-version 1.1.1
python3 scripts/native_release.py check
```

`set-version` 只同步自有 SDK 的版本：根 JSON、四个 Podspec、同版自有 Pod 依赖及 Shell/Cap HAR 元数据。Android publication 直接读取根 JSON。它不打 Git tag、不编译、不升级 Lynx/PrimJS/Gfx、不上传。

改 UI/原生工具功能按自有 SDK 的 SemVer 管理；引擎版本、Gfx 的 ABI 与两份 `.so` 冻结 SHA 是另一组已审依赖，不能靠修改版本字符串重标。SDK 依赖版本与 App/Bundle 投放范围沿原有职责管理，不新增 Bundle 协议版本门槛。

## 发布渠道与模块

| 平台 | 渠道 | 内容 |
| --- | --- | --- |
| Android | GitHub Packages Maven | Shell、Cap、Map 的 Debug/Release 变体与 sources；DebugTool 仅 Debug，必须保留 `.module` 元数据 |
| iOS | 本仓 `native-specs` 分支 + 原生 tag 源码 | 四个自有 Podspec JSON及实际使用的 AMapLocation 2.12.3 依赖描述 |
| Harmony | GitHub Release HAR | Shell/Cap 1.1.0、Gfx 4.1.0、固定版本下载工具及配置片段 |

OTA、监控核心和媒体后端仍随所属模块，Demo App 不作为公共 SDK 发布。JS 侧 `@cclx/lynx-native-bridge` 继续独立交付。

## 首次 CI 环境

工作流是 `.github/workflows/native-release.yml`，只接受 `workflow_dispatch`，不会因 push/PR 自动编译或发布。

- Android：GitHub `ubuntu-24.04`，配置固定 Gradle 8.11.1、Temurin JDK 21、SDK 36。原生 Java/Kotlin 目标保持 17，未升级 AGP/Kotlin。
- iOS：GitHub `macos-15-intel`，固定 CocoaPods 1.16.2；现有地图依赖需要该 x86_64 Simulator 路径。三个核心 Pod 以 Release、DebugKit 以 Debug 执行本地 `pod lib lint`，不运行单元测试；导出远程 Specs 时另核真实 Git 根路径、公开头、PrivacyInfo 和同版依赖。
- Harmony：需要仓库专用的 `[self-hosted, harmony-native]` Runner，预装 DevEco/Harmony SDK 6.1.1(API 24)与匹配的 Node/JDK/OHPM/Hvigor。当前已核对仓库 Runner 数量为 0；本轮没有安装或注册 Runner。

Harmony Runner 的进程环境应提供：

```text
DEVECO_SDK_HOME       实际 SDK 目录
NATIVE_OHPM_BIN       ohpm 可执行文件的绝对路径
NATIVE_HVIGOR_BIN     hvigorw 可执行文件的绝对路径
```

Runner PATH 使用 DevEco 该版本要求的 Node/JDK；先在维护环境确认工具链，再在仓库 Actions Variables 将 `HARMONY_RUNNER_READY` 设为 `true`。变量为空时 verify 明确跳过 Harmony，publish 在任何上传前失败。不能把部分平台成功标为三端通过。

公开仓库的自托管 Runner 只服务此仓，使用隔离的维护机器；流程不监听 PR/Fork，只允许可信 main 的精确 SHA进入 Harmony。它不能部署在持有正式 App 签名或生产数据的工作目录中。所有外部 Action 固定完整 commit SHA；源码编译 job 不持有仓库/包写权限。

## 手动验证与发布

1. 先合入已审 SDK 源码与这份配置，使工作流存在于 `main`。
2. 在 Actions 中选择 **Native SDK verification and release**，先运行 `mode=verify`。分支验证可构建 Android/iOS，Harmony 仅接受 main 且 Runner 已启用。
3. 核对三平台结果。Android 还编译只依赖 Staging Maven 的独立消费工程，检查 Debug/Release 的真实远程依赖形态。没有生成产物时不得继续。
4. 更新版本时先运行 `set-version`，提交全部同步元数据到 main。不要预先将同版本 tag 指向另一提交。
5. 从当前 main 手动运行 `mode=publish`。`release_tag` 可以留空；填写时必须等于根配置的 `native-v<version>`。三端构建通过后，流程创建同一 SHA的 tag/Draft Release，再发布 Maven 与 Specs，全部成功后公开 Release。

发布过程绑定唯一 sourceSHA、同一 run/批准的 build attempt、精确资产名单和 SHA256。Android 远程上传读取已验收 ZIP的原 AAR/POM/GMM/sources，不再次编译出另一份字节。公开前重新下载 Draft 资产比较内容。

CI 发布使用 GitHub 提供的 `GITHUB_TOKEN`，不要求把长期 token 放进源码。Maven job 只授予 packages 写权限；Release/Specs job 单独授予 contents 写权限。个人电脑消费 Maven 仍需 GitHub Packages 的读取认证。

## Android 消费

在业务工程的仓库配置中添加 GitHub Maven，并通过本机安全配置或 CI 环境提供读取凭据：

```kotlin
maven {
    url = uri("https://maven.pkg.github.com/fulisadawang/lynx-navigation-to-ota")
    credentials {
        username = providers.environmentVariable("GITHUB_USERNAME").get()
        password = providers.environmentVariable("GITHUB_PACKAGES_READ_TOKEN").get()
    }
}
```

```kotlin
dependencies {
    implementation("io.github.fulisadawang.lynx:lynx-shell-android:1.1.0")
    implementation("io.github.fulisadawang.lynx:lynx-capacitor-android:1.1.0")
    debugImplementation("io.github.fulisadawang.lynx:lynx-debug-tool-android:1.1.0")
}
```

Shell 默认依赖 Map；无需再次复制 Map 源码。保留 Gradle Module Metadata，不能禁用 `.module` 或只下载一个 AAR：它负责选择 Shell 的 Debug/Release，DebugTool 强制消费有诊断 SPI 的 Debug Shell。独立只引入 Cap 时，宿主仍需提供同版 Lynx Runtime。

## iOS 消费

首次发布成功后，在开发机器注册本仓独立 Specs 分支：

```bash
pod repo add lynx-native-specs https://github.com/fulisadawang/lynx-navigation-to-ota.git native-specs
```

```ruby
source 'https://github.com/fulisadawang/lynx-navigation-to-ota.git'
source 'https://github.com/lynx-family/Specs.git'
source 'https://cdn.cocoapods.org/'

platform :ios, '14.0'
use_modular_headers!
use_frameworks! :linkage => :static

pod 'LynxShellKit', '1.1.0'
pod 'LynxCapacitorKit', '1.1.0'
pod 'LynxShellDebugKit', '1.1.0', :configurations => ['Debug']
```

Specs 分支只存描述文件，Podspec 的源码仍从本仓 `native-v1.1.0` 获取。消费者不需要 `LYNX_NATIVE_REMOTE_SPEC` 或版本 JSON；该 ENV仅供 CI将本地开发 Podspec 导出为独立远程 JSON。本地 Demo 的 `:path` 方式继续保持，旧 Podfile.lock 需在获授权安装后更新。

AMapLocation 描述仍指向原官方 2.12.3 HTTP包；没有重新打包或修改第三方 framework。正式 App 的地图授权、隐私文案和业务配置仍由宿主负责。

## Harmony 消费

GitHub Releases 负责 HAR 分发，不提供 OHPM registry。先从同一 native tag 下载工具，再固定版本安装：

```bash
gh release download native-v1.1.0 \
  --repo fulisadawang/lynx-navigation-to-ota \
  --pattern native_harmony_release.py

python3 native_harmony_release.py install \
  --version 1.1.0 \
  --destination vendor/native \
  --config-root .
```

工具使用已有 gh 认证，下载该 tag 的描述、校验和及三份 HAR，校验元数据、版本、完整 SHA与 gfx 双 ABI冻结字节，然后只打印 `dependencies`/`overrides`片段。它不自动改业务配置、不执行 OHPM、不覆盖已有不同文件。按片段配置根工程的 gfx override及业务模块的 Shell/Cap依赖后，再执行正常 OHPM安装。

`--config-root` 只决定输出片段的路径基准。根工程与Entry模块通常有各自的 `oh-package.json5`，不能将同一相对路径原样粘贴两处。从工程根执行上面的安装命令后，文件位于 `vendor/native/`；若业务模块为 `entry/`，分别配置：

```json5
// 根工程 oh-package.json5
"overrides": { "@lynx/gfx": "file:./vendor/native/lynx-gfx-4.1.0.har" }
```

```json5
// entry/oh-package.json5
"dependencies": {
  "@lynx/lynx-shell-kit": "file:../vendor/native/lynx-shell-kit-1.1.0.har",
  "@lynx/lynx-capacitor-kit": "file:../vendor/native/lynx-capacitor-kit-1.1.0.har"
}
```

Gfx版本来自所选发行描述，工具可独立使用，不要求拥有当前源码目录或相邻 Module。消费者仍按原合同配置 Module注册、Ability/UIContext/Window、生命周期与系统回调。

## 失败与重复发布

- 验证模式不会上传；任一平台失败，发布阶段不执行。
- 同名 tag 指向另一 SHA、已公开 Release 或已有不同内容资产时停止，禁止覆盖/retag。
- Draft 同字节资产和已完整上传的同字节 Maven 模块可以复用；Maven 已部分写入或发生不同字节冲突时明确停止，保留 Draft，要求维护者核对或升级版本。
- 多注册表没有共同事务，流程不宣称原子回滚；不会自动删除已上传版本。Specs 已有同内容可复用，不同内容拒绝覆盖。
- `native-specs` 是隔离分支，只接受 `Specs/**`，使用显式普通 fast-forward 推送，不写 main。现有内容包含其它文件时停止，不清空用户分支。
- 新SDK Release正文由版本清单生成Android坐标、iOS Pod和Harmony安装命令，附件逐项列名，并将接入文档固定到本次sourceSHA。旧源码Release保留自己的历史范围，不将新SDK功能写回旧tag。

## 当前证据

Android 配置、iOS包装、Lynx发布链与CI安全分别进行独立只读审查，确认的问题按实际diff修正。源码复核不证明 Gradle任务图、CocoaPods/Xcode、Hvigor打包、GitHub Packages上传或其它项目已安装成功；这些由首次获授权的 CI验证。未新增单元测试、未执行原生编译、测试或包发布。Git配置交付以对应PR记录为准，推送配置不等于运行CI或发布SDK。

官方依据：[GitHub Gradle Packages](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-gradle-registry)、[CocoaPods CLI](https://guides.cocoapods.org/terminal/commands.html)、[Android多变体发布](https://developer.android.com/build/publish-library/configure-pub-variants)、[GitHub Runner列表](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。
