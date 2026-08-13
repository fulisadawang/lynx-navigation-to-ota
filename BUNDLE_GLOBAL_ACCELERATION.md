# Lynx Bundle 全球加速与 OTA 发布方案

> 状态：架构决策记录
> 更新时间：2026-08-07
> 适用范围：Android、iOS、HarmonyOS 的 Lynx OTA Bundle 下载与发布

## 1. 结论

全球使用同一个 Lynx Release 时，默认采用：

```text
一个主 OSS Bucket：fr-static-new
+
一个全球 CDN 域名：https://fr-static-new.huangbaoche.com
+
不可变 Bundle 地址、HTTPS、size/SHA-256 校验和客户端原子激活
```

不按中国、日本、欧洲、美国分别选择 OSS Bucket。其他地域 Bucket 只在区域容灾、数据驻留、
法规要求或不同市场需要不同 Release 时启用。

## 2. 已核实事实与待确认项

### 已核实

- `fr-static-new` 位于阿里云 OSS 杭州区域。
- Bucket 已提供全球传输加速端点：
  `fr-static-new.oss-accelerate.aliyuncs.com`。
- Bucket 同时提供海外传输加速端点：
  `fr-static-new.oss-accelerate-overseas.aliyuncs.com`。
- 自定义域名 `fr-static-new.huangbaoche.com` 的公开 DNS CNAME 指向
  `fr-static-new.huangbaoche.com.w.cdngslb.com`。
- HTTP 响应中的 `Via`、`X-Cache`、`x-oss-cdn-auth: success` 和 `Tengine`
  已证明自定义域名接入阿里云 CDN，并由 OSS 回源。
- 截至 2026-08-07，`https://fr-static-new.huangbaoche.com` 在多个公网 CDN 节点上
  TLS 握手失败。HTTP 根路径返回 `403` 只说明根路径不可访问，不能代表具体 Bundle 对象失败。
- OSS 官方全球传输加速域名的 HTTPS 握手正常；没有具体 Bundle 对象路径时，尚不能验证对象权限、
  `Content-Length`、缓存命中和 SHA-256。

### 待确认

- `[待确认]` CDN 控制台的加速区域是否为“全球”，而不是“全球（不包含中国内地）”。
- `[待确认]` 自定义域名的 HTTPS 证书、完整证书链和 TLS 配置是否已经修复并全网生效。
- `[待确认]` CDN 回源当前使用标准 OSS 域名还是 OSS 传输加速域名。
- `[待确认]` Bucket ACL、CDN 回源鉴权、URL 鉴权和防盗链策略。
- `[待确认]` Bundle 的实际对象路径、缓存规则、Range 请求和真实下载校验结果。

## 3. 最终访问链路

HTTPS 修复后，生产链路为：

```text
Android / iOS / HarmonyOS
        ↓ HTTPS
fr-static-new.huangbaoche.com
        ↓ 最近的阿里云 CDN 节点
        ├─ 缓存命中：边缘节点直接返回
        └─ 缓存未命中：回源 fr-static-new OSS
```

OTA API 对同一个 Release 向所有国家返回同一个 CDN URL。CDN 负责全球网络调度，OTA
服务端负责版本、灰度、禁用和回滚，两者职责不能混用。

## 4. Bundle URL 选择

| 用途 | URL | 结论 |
| --- | --- | --- |
| 生产主地址 | `https://fr-static-new.huangbaoche.com/{objectKey}` | HTTPS 修复并验收后使用 |
| 备用地址 | `https://fr-static-new.oss-accelerate.aliyuncs.com/{objectKey}` | CDN 故障降级或运维排查 |
| 仅海外场景 | `https://fr-static-new.oss-accelerate-overseas.aliyuncs.com/{objectKey}` | 中国内地用户也在范围内时不作为唯一地址 |
| 普通区域地址 | `https://fr-static-new.oss-cn-hangzhou.aliyuncs.com/{objectKey}` | 不作为全球客户端主地址 |

客户端不应感知具体 OSS 地域。将来更换源站或增加灾备时，只调整 CDN 和服务端配置，
不要求升级 App。

## 5. 对象路径与缓存

Bundle 使用内容不可变、带 Release 和 SHA-256 的对象路径：

```text
lynx-ota/{env}/{hostApp}/{lynxAppId}/{releaseId}/{sha256}/{bundleName}
```

示例：

```text
https://fr-static-new.huangbaoche.com/
lynx-ota/prod/capp/10000001/r20260807_001/{sha256}/home.lynx.bundle
```

禁止覆盖固定地址：

```text
/latest/main.bundle
/prod/current.bundle
```

建议缓存规则：

```http
# 带版本和哈希的 Bundle
Cache-Control: public, max-age=31536000, immutable

# latest-bundle-list、Manifest、policy/match 等版本决策接口
Cache-Control: no-store
```

新版本通过新 `releaseId` 和新 URL 发布，不依赖覆盖对象或全网强制刷新。发布前可以对新 URL
执行 CDN 预热，但预热成功不能替代真实下载和 SHA-256 校验。

## 6. 发布事务

推荐顺序：

```text
1. CI 构建一次 Bundle
2. 计算 size 和 SHA-256
3. 上传到 fr-static-new 的不可变对象路径
4. 从实际生产 CDN URL 下载回读
5. 校验 HTTP 状态、字节数和 SHA-256
6. 按需执行 CDN 预热
7. 创建 Release，但暂不激活
8. 完成冒烟、灰度检查后切换 ACTIVE
9. 异常时回滚 Release 指针，不覆盖或删除旧 Bundle
```

OTA API 返回字段示例：

```json
{
  "bundlePath": "home.lynx.bundle",
  "bundleUrl": "https://fr-static-new.huangbaoche.com/lynx-ota/prod/capp/10000001/r20260807_001/sha256-value/home.lynx.bundle",
  "bundleSha256": "sha256:64位小写十六进制",
  "size": 1234567
}
```

`x-ota-client-token` 只用于 OTA API，不能转发给 OSS/CDN，也不能写入 Bundle URL。

## 7. 客户端加载与磁盘不足

正常 OTA 主链路保持：

```text
请求版本元数据
→ 通过 CDN 下载 Bundle
→ 校验 HTTPS、2xx、非空、size 和 SHA-256
→ 写入 staging
→ 原子切换 current
→ 加载本地 current Bundle
```

CDN 解决全球下载速度和稳定性，不解决手机磁盘不足。磁盘不足时按以下顺序降级：

```text
已安装且校验有效的 current
→ previous
→ App 内置 Bundle
→ 清理本应用可回收的旧 Release 后重试
→ RemoteUrl 紧急降级
→ 原生错误页和明确用户提示
```

`open(RemoteUrl)` 可以使用生产 CDN URL，但只作为紧急降级；Runtime 仍可能占用内存、临时文件
或缓存，不能把它视为零存储方案。

## 8. HTTPS 修复后的验收清单

使用一条真实 Bundle URL 验证，不能只请求域名根路径：

```bash
dig +short CNAME fr-static-new.huangbaoche.com
curl -I "https://fr-static-new.huangbaoche.com/{真实Bundle对象路径}"
curl -H 'Range: bytes=0-1023' -I \
  "https://fr-static-new.huangbaoche.com/{真实Bundle对象路径}"
```

验收要求：

- [ ] HTTPS 握手成功，证书域名匹配且证书链完整。
- [ ] 完整请求返回 `200`，Range 请求按配置返回 `206`。
- [ ] `Content-Length` 与 Release 元数据一致。
- [ ] 响应存在 CDN 路径标识；第二次请求能够按缓存策略命中。
- [ ] 下载文件 SHA-256 与 `bundleSha256` 完全一致。
- [ ] Android、iOS、HarmonyOS 都能下载、校验、原子激活并加载。
- [ ] CDN 失败时不会破坏本地 `current`，仍能回退 `previous` 或内置 Bundle。
- [ ] 日志、URL 和仓库中没有 OTA Token、OSS 密钥或签名凭证。

## 9. 何时启用其他地域 Bucket

仅在下列情况增加法兰克福、东京、新加坡或美国源站：

- CDN 监控证明特定区域首包或回源质量不达标；
- 需要区域级灾备；
- 有数据驻留或监管要求；
- 不同市场确实需要不同 Release；
- 成本测算证明多源站优于单源站加 CDN。

如果只是同一份 Bundle 的全球下载，保持单主 Bucket + 全球 CDN，发布、校验和回滚链路最简单。

## 10. 官方参考

- [阿里云 OSS 传输加速](https://www.alibabacloud.com/help/en/oss/user-guide/transfer-acceleration)
- [阿里云 OSS 使用 CDN 加速](https://www.alibabacloud.com/help/en/oss/user-guide/cdn-acceleration)
- [阿里云 CDN 加速区域](https://www.alibabacloud.com/help/en/cdn/user-guide/change-the-accelerated-region)
