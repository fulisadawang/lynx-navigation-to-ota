# Lynx Bundle 目录

将 Playground 构建产物目录传给同步脚本，目录中的全部 `*.lynx.bundle` 和 `static/`
会复制到本目录：

```bash
cd /absolute/path/to/lynx-navigation-to-ota
./scripts/sync_bundle.sh /absolute/path/to/playground/dist
```

当前已导入 16 个 Bundle，包括 `main`、导航、媒体、存储、过渡和 Showcase 示例。

统一逻辑地址示例：

```text
assets://bundles/main.lynx.bundle
assets://bundles/nav-chain.lynx.bundle
```

也可使用 `local://bundles/<name>.lynx.bundle`；路由解析器会转换为 HarmonyOS rawfile
相对路径。页面由 Bundle 自己绘制，壳默认不叠加原生标题栏。
