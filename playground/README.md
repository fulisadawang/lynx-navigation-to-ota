# Lynx Shell Playground

这里复刻了 TikTok Sparkling Playground 的 Lynx 页面与 Bundle 组织方式，但不接入
Sparkling 原生 SDK、`sparkling-app-cli` 或 autolink。

来源：

- 仓库：`tiktok/sparkling`
- commit：`6de54387a823e87b0f0c42fcbf15dfd6c949ec2f`
- 上游目录：`packages/playground`
- License：Apache-2.0，见 `LICENSE.sparkling`

## 架构边界

- ReactLynx / Rspeedy 负责构建多页面 `.lynx.bundle`。
- 前端只调用官方全局对象 `NativeModules.LynxShellModule`。
- Android 使用当前工程手写的 Kotlin `LynxModule`，通过 `@LynxMethod` 导出方法。
- iOS 使用当前工程手写的 Swift `LynxModule`，通过 `methodLookup` 导出方法。
- 两端分别在 `LynxEnv` / `LynxConfig` 中显式注册 Module。
- 路由、关闭、存储、媒体选择、上传、下载和 Data URL 落盘均由宿主实现。
- 不依赖 `sparkling-method`、`spkPipe`、codegen 或 autolink。

## 构建

```bash
cd playground
pnpm install --frozen-lockfile
pnpm build
```

构建完成后，Bundle 与静态资源会自动同步到：

```text
ios/LynxShellSample/Resources/Bundles
android/app/src/main/assets/bundles
```

Android 还会把 `dist/static` 同步到大小写匹配的
`android/app/src/main/assets/Bundles/static`，供 Bundle 内的
`asset:///Bundles/` 静态资源地址读取。

首页产物是：

```text
main.lynx.bundle
```

## 本地 OTA 发布流水线

Playground 提供了不写入凭证的全量 OTA 发布脚本。它会读取 `dist/` 下的全部
`.lynx.bundle`，保留服务端当前完整 Release 中的旧 Bundle，再把 Playground Bundle 全部
上传到 OSS，生成新的完整快照。它不会自行猜测 `lynxAppId`，必须传入服务端已经存在的 App ID。

流水线顺序为：

```text
pnpm build
  -> 读取 dist/*.lynx.bundle
  -> 拉取 Android/iOS 当前完整 Release
  -> 按 bundlePath 复用旧 pageId
  -> 为新增 Bundle 分配 pageId
  -> ali-oss 上传 Playground 全部 Bundle
  -> OSS/CDN size + SHA 回读校验
  -> create DRAFT
  -> validate
  -> full publish
  -> 回读 Android/iOS latest
```

```bash
cd playground

# 当前 Android/iOS TEST OTA Demo 使用服务端已存在的 10000001。
# OSS 配置必须是本地 0600 JSON，文件内容不提交仓库。
LYNX_OTA_ENV=TEST \
LYNX_HOST_APP=capp \
LYNX_APP_ID=10000001 \
LYNX_PLATFORMS=android,ios \
LYNX_BUILD_VERSION=codex-YYYYMMDD-playground-all-v1 \
LYNX_PAGE_ID=1113 \
LYNX_OSS_CONFIG=/absolute/path/to/oss.local.json \
LYNX_OSS_REGION=oss-cn-hangzhou \
LYNX_OSS_BUCKET=fr-static-new \
LYNX_OSS_PUBLIC_BASE_URL=https://fr-static-new.oss-cn-hangzhou.aliyuncs.com \
LYNX_OSS_PREFIX=cappLynx/lynx \
CI_RELEASE_TOKEN='<CI token>' \
pnpm ota:build-and-publish

# 只检查完整快照，不上传、不创建 Release
LYNX_OTA_ENV=TEST \
LYNX_HOST_APP=capp \
LYNX_APP_ID=10000001 \
LYNX_PLATFORMS=android,ios \
LYNX_BUILD_VERSION=codex-YYYYMMDD-playground-all-v1 \
LYNX_PAGE_ID=1113 \
LYNX_OSS_REGION=oss-cn-hangzhou \
LYNX_OSS_BUCKET=fr-static-new \
LYNX_OSS_PUBLIC_BASE_URL=https://fr-static-new.oss-cn-hangzhou.aliyuncs.com \
LYNX_OSS_PREFIX=cappLynx/lynx \
CI_RELEASE_TOKEN='<CI token>' \
pnpm ota:publish:dry-run -- --dry-run
```

`LYNX_PAGE_ID=1113` 是基于当前 `10000001` Release 已使用到 `1112` 的下一段起始值；脚本
仍会按 `bundlePath` 复用已有 pageId。当前脚本不会把 CI token、OSS key 或 secret 放入源码、
Bundle、日志或文档。

## 官方 Bundle 示例库

首页点击“官方 Bundle 示例”进入 `go-bundles.lynx.bundle`。页面内置用户提供的
`go-lynxjs-lynx-bundle-urls.txt` 快照，共 565 个 `go.lynxjs.org` 示例，支持：

- 按示例目录分类；
- 按分类、名称和相对路径搜索；
- 每次最多追加渲染 40 项；
- 通过手写 `NativeModules.LynxShellModule` 打开远程 HTTPS Bundle。

当前三端壳不配置远程 Host 白名单，但仍要求 HTTPS、`.lynx.bundle` 后缀、响应码和体积
限制。部分在线示例可能依赖更新版 Lynx、额外原生组件或网络资源，因此“导航已提交”和
“页面完整渲染”仍需分开判断。

## 高级导航演示

首页点击“导航栈”进入 `nav-chain.lynx.bundle`，可操作验证：

- A-B-C-D-E push；
- `back(2)`、`popTo(A)`；
- `singleTop / clearTop / singleTask`；
- `redirect(A)`；
- 原生栈状态查询；
- 页面结果返回与一次性消费；
- `closeAll / reLaunch`。

全部页面调用仍只进入 `NativeModules.LynxShellModule`。完整 API 和宿主接线见根目录
[NAVIGATION_README.md](../NAVIGATION_README.md)。

## 原生容器转场演示

首页点击“原生容器转场”进入 `transition-gallery.lynx.bundle`，目标页为
`transition-detail.lynx.bundle`。演示包含：

- 跨真实 Activity / UIViewController 的多 share-element；
- Open Container 裁剪双内容容器；
- fade、slide、none；
- Skyline 七种 routeType 与 heroSheet 多档位扩展；
- Bundle 预取、消费与取消；
- 一次性业务 ready、`onRouteDone` 和原生转场状态查询；
- edge 返回完成与取消。

两页只通过手写 `NativeModules.LynxShellModule` 声明 selector 和意图，不上报屏幕
坐标，也不逐帧驱动原生动画。完整协议见
[TRANSITIONS_README.md](../TRANSITIONS_README.md)。

业务页面优先使用简洁预设：

```ts
navigateWithPreset({ bundle: 'detail.lynx.bundle', preset: 'zoom' })

navigateSharedElement({
  bundle: 'detail.lynx.bundle',
  key: 'hero',
})

navigateOpenContainer({
  bundle: 'detail.lynx.bundle',
  source: 'card-source',
})
```

完整 `transition` JSON 只保留为框架层高级逃生口。
