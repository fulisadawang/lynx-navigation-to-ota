该目录由根目录 `playground/` 的 `pnpm build` 自动更新，默认入口是
`main.lynx.bundle`。

工程将此目录作为 Folder Reference 加入 Copy Bundle Resources，因此新增 Bundle 后不必逐个修改 Xcode Build Phase。
