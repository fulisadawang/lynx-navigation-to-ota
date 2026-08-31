# OTA Store v3 本地 Golden Fixture

`ota-store-v3-golden-100-v1-v2/` 是本地测试运行目录，不提交生成的 `.lynx.bundle` 二进制。使用 Playground 的 ReactLynx/Rspeedy 编译链生成：

```bash
cd playground
pnpm ota:v3:fixture
pnpm ota:v3:fixture:verify
```

Fixture 固定为：

- V1：100 个 Bundle；
- V2：100 个 Bundle；
- 只有 `pages/10000001/bundle-050.lynx.bundle` 的内容、size 和 SHA-256 变化；
- iOS、Android、HarmonyOS 各有完整 Manifest，Bundle bytes/SHA 共用同一份 Golden 内容；
- 输出目录被 `.gitignore` 忽略，删除后可以重复生成。

启动本地 OTA Server：

```bash
cd playground
pnpm ota:v3:server
```

默认监听 `127.0.0.1:18765`。Server 只用于 TEST/本地验收，不需要 token，也不模拟真实生产鉴权或 OSS。
