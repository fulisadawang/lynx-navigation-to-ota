# Bundle 加载测试夹具

本目录仅用于 `docs/bundle-loading-opt/TEST_CASES.md` 的 BL-R01–04、BL-P01。
验收脚本先于页面实现落地；构建成功只证明产物生成和归档核对，实际首屏、脚本执行及性能由原生测试宿主确认。

## 固定断言

| 页面 | 编译设置 | 必须运行的内容 |
| --- | --- | --- |
| `BundleLoadSmall.lynx.bundle` | `inlineScripts=true` | 显示 `BUNDLE_LOADING_FIXTURE_V1`，ready 的 moduleCount/payloadLength/checksum 均为 0 |
| `BundleLoadLarge.lynx.bundle` | `inlineScripts=true` | 固定 xorshift32 种子生成 3 MiB 字符串，背景 useEffect 校验真实长度及每 4093 字节采样摘要；实际 Bundle 为 2–4 MiB |
| `BundleLoadAsync.lynx.bundle` | `inlineScripts=false` | 调用 10 个独立计算模块，校验合计 56430；实际产物为 10 个业务外部 JS，入口 background 由当前 encoder 消费到主 Bundle，全部实际外部脚本归档到 Async 清单 |

主线程 chunk 不参与 splitChunks。夹具只用 `view`/`text`/`scroll-view`，不加载图片、字体或网络业务数据。
错误显示 `FAILED` 与实际原因；Native handler 未注册或回执非零不能显示成功。原生调用只发生在背景 useEffect/handler。

## 构建与归档验证

在仓库根运行（仅在已授权构建时）：

```bash
node scripts/bundle-loading-opt/build-fixtures.mjs
node scripts/fixtures/bundle-loading/verify-fixtures.mjs /tmp/codex-bundle-loading-opt-20261009/implementation/fixture-out
```

构建脚本固定 `mode=production`，只借用模板已安装的 node_modules，通过本目录临时符号链接解析依赖，不修改模板源码、配置、dist 或安装依赖。
构建进程同时设置 `NODE_ENV=production`，并用 `source.define` 替换 `process.env.NODE_ENV`。
这是 ReactLynx 插件读取进程环境的编译期要求，不向原生 JS Runtime 注入 `process`。
可使用 `--dependencies <node_modules>`、`--out <directory>`、`--asset-prefix <URL>` 指定依赖和输出。
输出目录必须为空，复现实验请传入新的输出目录，避免覆盖已有归档。
生成数据、构建临时目录、符号链接都不提交。`fixture-metadata.json` 记录真实 size、SHA、预期结果及 owner/requestKey 索引。
requestKey 为以 `/` 开头的逻辑路径，url 为真实下载 URL，requestAliases 同时记录完整 URL 和 URL path。
预检使用已安装的 TASM 解码实际 Bundle，再以 Acorn 与 eslint-scope 检查内联及外部背景脚本。
任何未声明的可执行 `process` 引用都会失败；字符串、注释、属性名和合法局部变量不会误报。`runtimePreflight` 记录检查计数和每个实际脚本摘要，独立 verifier 会重新执行检查。
默认脚本前缀为本机测试地址，若运行宿主使用其他地址，构建时指定前缀；更换前缀会改变编译产物 SHA，必须整体重新归档。

## Native 回执

每页完成必要计算后通过已有 Shell Module 发出：

```text
eventName: bundle-loading-bench.ready
payload: { caseName: small|large|async, moduleCount, payloadLength, checksum }
```

计算成功后页面结果 `text` 具有 `id="bundle-bench-ready"`，`accessibility-label` 与可见文字均为
`bundle-bench:<caseName>:payload=<length>:checksum=<checksum>:scripts=<moduleCount>`。
该标签表示真实脚本计算完成，Native 回执状态独立显示；Native 失败另有 `id="bundle-bench-error"`，不会伪造 Native 接受。
元数据的 `expectedReadyLabel` 是原生截图／可访问性断言的精确值。

测试宿主必须注册 MessageHandler，校验这四个字段，再返回 `{ code: 0 }`。字段与 `fixture-metadata.json` 中 `expectedReadyPayload` 完全相同。
页面状态和 Native 回执不替代 SDK 首屏回调；宿主计时不可采用页面伪造的时间戳。夹具不自行激活 OTA、不上传、不操作设备。
