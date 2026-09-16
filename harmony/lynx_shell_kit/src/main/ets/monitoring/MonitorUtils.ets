/** 监控边界的小型纯函数；不读取 OTA 文件，也不改变页面状态。 */
import cryptoFramework from '@ohos.security.cryptoFramework';
import { BundleIdentity, BundleIdentityValue, BundleSource } from './MonitorTypes';

/** 统一事件协议要求 UUID v4；prefix 仅为兼容现有调用点保留，不写入 ID。 */
export function monitorId(_prefix: string): string {
  const bytes: Uint8Array = cryptoFramework.createRandom().generateRandomSync(16).data;
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex: string[] = Array.from(bytes).map((byte: number) => byte.toString(16).padStart(2, '0'));
  return `${hex.slice(0, 4).join('')}-${hex.slice(4, 6).join('')}-${hex.slice(6, 8).join('')}-` +
    `${hex.slice(8, 10).join('')}-${hex.slice(10, 16).join('')}`;
}

export function monitorBundleIdentity(
  source: string,
  lynxAppId: string,
  bundleName: string,
  releaseId: string,
  releaseSequence: string | null,
  sha256: string
): BundleIdentity {
  const normalizedSource: BundleSource = source === 'embedded' || source === 'embedded_baseline'
    ? 'embedded'
    : source === 'direct_https' ? 'direct_https'
      : source === 'direct_asset' ? 'direct_asset' : 'ota';
  const normalizedSha = sha256.trim().toLowerCase().replace('sha256:', '');
  const validSha = /^[0-9a-f]{64}$/.test(normalizedSha);
  const sequence = releaseSequence === null ? null : releaseSequence.trim();
  const validSequence = sequence !== null && /^(0|[1-9][0-9]*)$/.test(sequence);
  return new BundleIdentityValue(
    normalizedSource, lynxAppId, bundleName, releaseId, validSequence ? sequence : null,
    validSha ? normalizedSha : null,
    validSha ? 'verified' : 'unavailable',
    validSha ? null : 'prepared_bundle_sha256_invalid', null
  );
}

export function unavailableBundleIdentity(reason: string): BundleIdentity {
  return new BundleIdentityValue('direct_asset', null, null, null, null, null, 'unavailable', reason, null);
}

export function finiteNumber(value: Object | undefined): number | null {
  if (value === undefined) return null;
  const numberValue = Number(value);
  if (!Number.isFinite(numberValue) || numberValue < 0) return null;
  return numberValue;
}

export function monitorTruncate(value: string, maxLength: number): string {
  return value.length <= maxLength ? value : value.substring(0, maxLength);
}

/** Provider 前统一移除 URL 查询、Cookie 和常见凭据值，避免错误堆栈携带业务秘密。 */
export function monitorSanitize(value: string): string {
  const urlPattern = new RegExp("https?:\\/\\/[^\\s<>\"')]+", "g");
  const secretPattern = new RegExp("\\b(token|cookie|password|authorization|access[_-]?token|refresh[_-]?token)\\s*[:=]\\s*[^\\s,;]+", "gi");
  const bearerPattern = new RegExp("\\bBearer\\s+[^\\s,;]+", "gi");
  let result = value.replace(urlPattern, (url: string) =>
    url.split('?')[0].split('#')[0]);
  result = result.replace(secretPattern, '$1=[redacted]');
  return result.replace(bearerPattern, 'Bearer [redacted]');
}

/** 只接受构建产物登记格式的 debugmetadata key，不从文件名或 SHA 猜测。 */
export function monitorDebugKey(value: string): string | null {
  const match = new RegExp("debugmetadata:([A-Za-z0-9._/-]+)", "i").exec(value);
  return match === null ? null : match[1];
}

export function monitorUtf8Bytes(value: string): number {
  let bytes = 0;
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index);
    if (code <= 0x7f) {
      bytes += 1;
    } else if (code <= 0x7ff) {
      bytes += 2;
    } else if (code >= 0xd800 && code <= 0xdbff && index + 1 < value.length) {
      const next = value.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        bytes += 4;
        index += 1;
      } else {
        bytes += 3;
      }
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

export function monitorJsonBytes(value: Object): number {
  const serialized = JSON.stringify(value);
  return serialized === undefined ? 0 : monitorUtf8Bytes(serialized);
}
