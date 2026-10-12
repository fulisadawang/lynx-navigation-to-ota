# 静态 Engine 复用 Fixture

此 Fixture 与原 Small/Large/Async、State/Lazy 输入完全分离。源码只读取 `useInitData` 与
`useGlobalProps`，再由 `root.render` 输出当前 marker/pageId；构建脚本拒绝 `useEffect`、`useState`、
Native 调用与定时器。

构建输出必须在仓库外且为空：

```sh
node scripts/fixtures/engine-reuse-static/build.mjs /tmp/codex-engine-reuse-20261010/engine-static/fixture-out
```

将生成的 Bundle 和 `fixture-metadata.json` 放入验收 App 私有 files 的
`engine-reuse-static/` 后，运行 `StaticEngineWarmFrameTest`。该测试不替代原固定 Bundle 的完整
Source、Async 或内存验收。
