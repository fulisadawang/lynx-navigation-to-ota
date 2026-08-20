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
