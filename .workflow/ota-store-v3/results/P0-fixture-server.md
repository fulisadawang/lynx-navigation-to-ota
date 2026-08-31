# P0 Result — Playground Fixture 与本地 OTA Server

> 历史说明：本文件记录 P0 阶段的 Fixture/Server 冻结结果；其中关于“待增加”的客户端接线边界已在 P1–P3 完成。

## 结果

- 使用 Playground 的 ReactLynx/Rspeedy 编译链生成 V1/V2 Bundle：两个版本各 100 个，只有 `pages/10000001/bundle-050.lynx.bundle` 的 bytes、size、SHA-256 变化。
- `node scripts/verify-ota-store-v3-fixture.mjs --fixture playground/fixtures/ota-store-v3-golden-100-v1-v2`：PASS。
- 本地 Server：`http://127.0.0.1:18765`，仅用于 TEST 验收，不需要凭证。
- latest-bundle-list 返回完整 100 条 `changedBundles`；release Manifest 返回完整 100 条 `bundles`。
- V1/V2 Bundle 二进制可下载；Server 支持 V1/V2 切换、ETag/304、latest/Manifest 404、Bundle 404、断开、错误 SHA/size、空列表和 metrics。
- 已用 curl 验证 health、V1 latest、V1 Manifest、V1 Bundle 下载、切换 V2、V2 完整条目数和请求计数。

## P0 冻结

- Manifest 保持完整快照，不设计 patch/delta 链。
- Server 的 latest index 可以轻量化，但本地激活前必须拿到完整 Manifest。
- v3 客户端对象层按 App ID + SHA-256 CAS 去重；本地 fixture Server 只模拟接口和二进制，不预先模拟客户端存储。

## 运行方式

```bash
cd playground
pnpm ota:v3:fixture
pnpm ota:v3:fixture:verify
cd ..
node scripts/ota-store-v3/local-server.mjs \
  --fixture playground/fixtures/ota-store-v3-golden-100-v1-v2 \
  --host 127.0.0.1 --port 18765
```

当前生成的 `playground/fixtures/ota-store-v3-golden-100-v1-v2/` 已加入 `.gitignore`，删除后可重复生成；脚本和 fixture 说明会进入版本库。

## 边界

- 本地 Server 不等价于真实外部 OTA Server；本轮用于隔离网络环境，保证客户端可以真实走 HTTP 请求、完整 Manifest、Bundle 下载和错误响应。
- 当前客户端仍强制生产 HTTPS；iOS P1 需要增加仅 TEST/Debug 的本地 HTTP 配置入口，Release 保持 HTTPS 拒绝。
