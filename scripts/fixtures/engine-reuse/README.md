# Android Engine Reuse Fixture

只用于 `LynxViewGroup` 复用验收。两个主包及一个真正独立的 lazy component Bundle，不引用旧的 `bundle-loading` fixture；模板现有 `node_modules` 只通过本目录的符号链接读取。

```sh
node scripts/android-engine-reuse/build-fixtures.mjs
node scripts/fixtures/engine-reuse/verify-fixtures.mjs
node /Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxAppPackagesAndTemplates/templates/lynx-template/node_modules/typescript/bin/tsc -p scripts/fixtures/engine-reuse/tsconfig.json --noEmit
```

默认输出 `/tmp/codex-engine-reuse-20261010/android-group-cache/fixture-out`，目录必须为空。可传 `--out`、`--dependencies`、`--asset-prefix`。不会安装、升级依赖或调用 Server/发布接口。

## 真实初始数据与 React 状态

`StateProbe` 和 `LazyProbe` 使用当前安装的 `@lynx-js/react@0.123.3` 真实导出的 `useInitData()` / `useGlobalProps()`。宿主每次打开页面须输入：

| 位置 | 首次页面 | 再次打开 |
| --- | --- | --- |
| initData | `marker` 与 `oldOnly` | 新 `marker`，完全省略 `oldOnly` |
| globalProps | `probePageId`、`marker`、`oldOnly` | 新 `probePageId` 与 `marker`，完全省略 `oldOnly` |

`probePageId` 必须与 `ShellMessageHub` 注册的真实 source pageId 相同。字段省略与字段赋空串不同，探针通过 `Object.prototype.hasOwnProperty.call` 判断是否存在。

事件 `engine-reuse-probe.ready` 输出：`fixture`、`caseName`、`phase`（`initial` / `counter`）、`pageId`、`marker`、`globalMarker`、`hasOldOnly`、`globalHasOldOnly`、`counter`、`moduleMountCount`。lazy 主页面额外输出 `lazyStatus: 'not-requested'`。`counter` 是真实 `useState(0)`，`moduleMountCount` 由背景线程模块变量在 `useEffect` 中递增。

Native `reply.code === 0` 后才显示 `engine-reuse-ready`，其 accessibility label 形如 `engine-reuse:state:page=<pageId>:marker=<marker>:counter=0:mount=1:oldOnly=false:globalOldOnly=false`。回执错误显示 FAILED。`engine-reuse-increment` 点击让真实 counter 加一并再次发送回执。

## 真实独立 lazy Bundle

`LazyPanel.tsx` default export 通过 `experimental_isLazyBundle: true` 单独构建 `lazy-bundle/EngineReuseLazyPanel.lynx.bundle`。消费者入口导入 `@lynx-js/react/experimental/lazy/import`，用 `lazy(() => import(url, { with: { type: 'component' } }))` 和 `Suspense` 加载；初始 `visible=false`，只在点击 `engine-reuse-load-lazy` 后渲染组件。没有 frame、子 LynxView 或外置背景 JS chunk。

组件挂载后发送 `engine-reuse-probe.lazy-ready`，增加 `component: 'EngineReuseLazyPanel'`、`phase: 'lazy-mounted'`、`lazyStatus: 'mounted'`，同时报告页面 marker、pageId、旧字段 hasOwn 和 lazy 模块 mount 计数。Native 接受后才出现 `engine-reuse-lazy-ready`，label 为 `engine-reuse:lazy-mounted:page=<pageId>:marker=<marker>:mount=1`。

`fixture-metadata.json` 中记录真实 owner、requestKey、URL、SHA、size。默认 URL 是 `http://127.0.0.1:18782/lazy-bundle/EngineReuseLazyPanel.lynx.bundle`，requestKey 是 `/lazy-bundle/EngineReuseLazyPanel.lynx.bundle`，owner 是 `EngineReuseLazyProbe.lynx.bundle`。本机验收可由 Store fixture 提供该路径；构建脚本不建立 HTTP 服务。

## 验证边界

构建固定 production、Engine 4.1、FetchBundle loader，解码主包背景脚本以及 lazy 的 `custom-sections/background`，使用 Acorn AST 与 eslint-scope 确认无自由 `process` 引用。主线程 section 为已编译 bytecode，AST 校验的直接对象是可解码的背景源码及构建目录中实际存在的 JS 文件。校验还确认 lazy 回执代码仅属于独立 bundle、消费者只含确定 URL、没有外置 JS chunk。

类型检查、scanner、Bundle 构建和解码通过仅证明源码及产物满足预检。旧字段是否清除、counter 是否归零、模块 mount 是否重置、lazy provider 是否按新页面重绑，仍须由 Android 真运行及 Native 回执证明。

API 依据：[ReactLynx Code Splitting](https://lynxjs.org/react/code-splitting.html)、安装依赖的 `runtime/lib/lynx-api.js` 与 `runtime/lib/core/lynx/lazy-bundle.js`、插件 `dist/index.js`。
